using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;
using System.Text;
using System.Threading;

namespace KidFBY
{
    static class Program
    {
        const string SingleInstanceMutexName = @"Local\KidFBY.SingleInstance";
        const int BootWaitHalfSeconds = 240; // 240 x 500 ms = 120 s

        static bool noUi;
        static string logDir;
        static string currentBackupDir;

        class RecoveryException : IOException
        {
            public RecoveryException(string message) : base(message) { }
            public RecoveryException(string message, Exception inner) : base(message, inner) { }
        }

        static string LogPath()
        {
            return Path.Combine(logDir, "launcher-" + DateTime.Now.ToString("yyyyMMdd") + ".log");
        }

        static void Log(string message)
        {
            try
            {
                Directory.CreateDirectory(logDir);
                File.AppendAllText(LogPath(), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + "\r\n", Encoding.UTF8);
            }
            catch (Exception)
            {
                // The log itself must never take the launcher down; there is nowhere else to report this.
            }
        }

        static void Notify(string text, MessageBoxIcon icon)
        {
            Log(text.Replace("\r", "").Replace("\n", " | "));
            if (noUi) return;
            MessageBox.Show(text, "Kid FB.Y", MessageBoxButtons.OK, icon);
        }

        [STAThread]
        static void Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            logDir = Path.Combine(baseDir, "logs");
            bool selfTest = args != null && Array.IndexOf(args, "-SelfTest") >= 0;
            noUi = selfTest || Environment.GetEnvironmentVariable("KID_FBY_NO_MSGBOX") == "1";
            // -AfterUpdate: started by the old GUI right before it closes; wait for the old launcher to exit.
            bool afterUpdate = args != null && Array.IndexOf(args, "-AfterUpdate") >= 0;
            if (afterUpdate)
            {
                System.Collections.Generic.List<string> kept = new System.Collections.Generic.List<string>();
                foreach (string a in args) if (a != "-AfterUpdate") kept.Add(a);
                args = kept.ToArray();
            }
            Mutex single = null;
            try
            {
                // First thing: one launcher per user session. KID_FBY_ALLOW_MULTI is for build/test checks only.
                if (afterUpdate && Environment.GetEnvironmentVariable("KID_FBY_ALLOW_MULTI") != "1")
                {
                    single = new Mutex(false, SingleInstanceMutexName);
                    bool got;
                    try { got = single.WaitOne(60000); }
                    catch (AbandonedMutexException) { got = true; } // previous owner died: we own it now
                    if (!got)
                    {
                        single.Dispose();
                        single = null;
                        Environment.ExitCode = 2;
                        Notify("Kid FB.Y bản cũ chưa thoát sau 60 giây nên không áp dụng được bản cập nhật.\nHãy đóng Kid FB.Y rồi mở lại.", MessageBoxIcon.Warning);
                        return;
                    }
                    Log("-AfterUpdate: da lay mutex sau khi launcher cu thoat.");
                }
                else if (Environment.GetEnvironmentVariable("KID_FBY_ALLOW_MULTI") != "1")
                {
                    bool createdNew;
                    single = new Mutex(true, SingleInstanceMutexName, out createdNew);
                    if (!createdNew)
                    {
                        single.Dispose();
                        single = null;
                        Environment.ExitCode = 2;
                        Notify("Kid FB.Y đang chạy.\nHãy dùng cửa sổ Kid FB.Y đang mở.", MessageBoxIcon.Information);
                        return;
                    }
                }

                Log("Khoi dong launcher " + CurrentFileVersion() + " tai " + baseDir + (selfTest ? " (SelfTest)" : ""));
                string updDir = Path.Combine(baseDir, "core", "_update");
                AcquireUpdateLock(updDir);
                RecoverPending(baseDir, updDir);

                string coreDir = Path.Combine(baseDir, "core");
                if (!Directory.Exists(coreDir))
                {
                    Directory.CreateDirectory(coreDir);
                }

                string guiFile = Path.Combine(coreDir, "kid-fby-gui.ps1");

                // Lam moi script/tai nguyen nhung theo phien ban EXE (sau RecoverPending).
                EnsureResources(coreDir);

                if (!File.Exists(guiFile))
                {
                    Environment.ExitCode = 1;
                    Notify("Không tìm thấy file khởi chạy giao diện:\n" + guiFile,
                        MessageBoxIcon.Error);
                    return;
                }

                // Ap dung ban cap nhat da tai san (neu co)
                string backupDir = null;
                bool applied = ApplyUpdate(baseDir, updDir, out backupDir);
                currentBackupDir = backupDir;

                Process proc = LaunchGui(guiFile, baseDir, args);

                if (applied && backupDir != null)
                {
                    // Cho GUI moi bao BOOT_OK (toi da 120 s); chet som / het gio -> rollback
                    bool ok = false;
                    for (int i = 0; i < BootWaitHalfSeconds; i++)
                    {
                        if (BootConfirmed(updDir, backupDir)) { ok = true; break; }
                        if (proc.HasExited)
                        {
                            System.Threading.Thread.Sleep(300);
                            if (BootConfirmed(updDir, backupDir)) ok = true;
                            break;
                        }
                        System.Threading.Thread.Sleep(500);
                    }
                    if (!ok)
                    {
                        Log("GUI khong bao BOOT_OK (da thoat=" + proc.HasExited + "); rollback ban cap nhat.");
                        try { if (!proc.HasExited) proc.Kill(); }
                        catch (Exception killError) { Log("Khong ket thuc duoc GUI: " + killError.Message); }
                        if (!proc.HasExited && !proc.WaitForExit(10000))
                            throw new IOException("Khong dung duoc GUI de khoi phuc. Du lieu phuc hoi van duoc giu lai.");
                        MarkUpdateFailed(updDir);
                        RestoreBackup(baseDir, backupDir);
                        FinishTransaction(updDir, backupDir);
                        Notify("Bản cập nhật mới không khởi động được.\nĐã tự động khôi phục bản cũ.\nChi tiết: " + LogPath(),
                            MessageBoxIcon.Warning);
                        proc = LaunchGui(guiFile, baseDir, args);
                    }
                    else FinishTransaction(updDir, backupDir);
                }

                // GUI's own updater needs the transaction lock; keep only the single-instance mutex.
                ReleaseUpdateLock();

                // Early-crash detection, then stay alive (holding the mutex) until the GUI exits.
                bool exited = proc.WaitForExit(15000);
                if (exited && proc.ExitCode != 0 && !selfTest)
                {
                    Environment.ExitCode = proc.ExitCode;
                    Notify("Không khởi động được Kid FB.Y (mã lỗi " + proc.ExitCode + ").\nXem nhật ký: " + LogPath(),
                        MessageBoxIcon.Error);
                }
                else if (!exited) proc.WaitForExit();
                Log("GUI thoat, ma " + proc.ExitCode);
                if (selfTest) Environment.ExitCode = proc.ExitCode;
            }
            catch (RecoveryException rex)
            {
                Environment.ExitCode = 1;
                Log("RecoveryException: " + rex);
                string where = currentBackupDir != null ? currentBackupDir : Path.Combine(baseDir, "core", "_backup");
                Notify("Dữ liệu phục hồi sau cập nhật bị thiếu hoặc hỏng, nên Kid FB.Y không khởi động để tránh làm hỏng file.\n\n" +
                    rex.Message + "\n\nThư mục: " + where +
                    "\n\nCách xử lý: đóng Kid FB.Y, sao lưu rồi xóa thư mục core\\_backup (và core\\_update nếu có), sau đó mở lại. " +
                    "Nếu app vẫn lỗi, hãy tải lại bản đầy đủ mới nhất.\nNhật ký: " + LogPath(),
                    MessageBoxIcon.Error);
            }
            catch (Exception ex)
            {
                Environment.ExitCode = 1;
                Log("Loi khoi dong: " + ex);
                Notify("Lỗi khởi động Kid FB.Y:\n\n" + ex.Message + "\n\nNhật ký: " + LogPath(),
                    MessageBoxIcon.Error);
            }
            finally
            {
                ReleaseUpdateLock();
                if (single != null)
                {
                    try { single.ReleaseMutex(); }
                    catch (ApplicationException releaseError) { Log("Khong nha duoc mutex: " + releaseError.Message); }
                    single.Dispose();
                }
            }
        }

        // Quote one argument per the CommandLineToArgvW rules.
        internal static string QuoteArg(string arg)
        {
            if (arg == null) arg = "";
            if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"', '[', ']' }) < 0) return arg;
            StringBuilder sb = new StringBuilder();
            sb.Append('"');
            int backslashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\') { backslashes++; }
                else if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1);
                    sb.Append('"');
                    backslashes = 0;
                }
                else
                {
                    sb.Append('\\', backslashes);
                    backslashes = 0;
                    sb.Append(c);
                }
            }
            sb.Append('\\', backslashes * 2);
            sb.Append('"');
            return sb.ToString();
        }

        static string PowerShellPath()
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(path)) throw new IOException("Không tìm thấy Windows PowerShell: " + path);
            return path;
        }

        static Process LaunchGui(string guiFile, string baseDir, string[] args)
        {
            StringBuilder arguments = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ");
            arguments.Append(QuoteArg(guiFile));
            if (args != null)
                foreach (string a in args) arguments.Append(' ').Append(QuoteArg(a));
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = PowerShellPath();
            psi.Arguments = arguments.ToString();
            psi.WorkingDirectory = baseDir;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.EnvironmentVariables.Remove("KID_FBY_UPDATE_TOKEN");
            string pendingBackup = Path.Combine(baseDir, "core", "_backup");
            if (File.Exists(Path.Combine(pendingBackup, "JOURNAL")))
                psi.EnvironmentVariables["KID_FBY_UPDATE_TOKEN"] = ReadToken(pendingBackup);
            Log("Chay GUI: " + psi.FileName + " " + psi.Arguments);
            return Process.Start(psi);
        }

        static string CurrentFileVersion()
        {
            return FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location).FileVersion;
        }

        static void ReleaseUpdateLock()
        {
            if (updateLock != null) { updateLock.Dispose(); updateLock = null; }
        }

        // Ghi file qua .tmp roi thay the; .bak chi ton tai trong luc thay va bi xoa khi thanh cong.
        static void WriteAtomic(string path, byte[] data)
        {
            string tmp = path + ".tmp", bak = path + ".bak";
            try
            {
                using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    fs.Write(data, 0, data.Length);
                    fs.Flush(true);
                }
                for (int i = 0; ; i++)
                {
                    try
                    {
                        if (File.Exists(path)) File.Replace(tmp, path, bak, true);
                        else File.Move(tmp, path);
                        break;
                    }
                    catch (IOException) { if (i >= 3) throw; System.Threading.Thread.Sleep(250); }
                }
                if (File.Exists(bak))
                {
                    try { File.Delete(bak); }
                    catch (IOException bakError) { Log("Khong xoa duoc " + bak + ": " + bakError.Message); }
                }
            }
            catch (Exception ex)
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); }
                catch (IOException tmpError) { Log("Khong xoa duoc " + tmp + ": " + tmpError.Message); }
                throw new IOException("Không ghi được file: " + path + "\n(" + ex.Message + ")", ex);
            }
        }

        static readonly string[] EmbeddedResources = new string[] {
            "kid-fby-gui.ps1", "kid-fby.ps1", "whisper-language.ps1", "facebook-links.ps1", "fix-ket-noi.ps1",
            "Kid-FB.Y.ico", "kid-logo.zip", "ui/Theme.xaml", "ui/MainWindow.xaml" };

        // Ten resource trong EXE: "ui/Theme.xaml" -> "ui.Theme.xaml" (csc /res:core\ui\Theme.xaml,ui.Theme.xaml).
        static string ResourceLogicalName(string relativePath)
        {
            return relativePath.Replace('/', '.').Replace('\\', '.');
        }

        static string ResourceTargetPath(string coreDir, string relativePath)
        {
            return Path.Combine(coreDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
        }

        static byte[] ReadResource(Assembly asm, string resName)
        {
            resName = ResourceLogicalName(resName);
            string match = null;
            foreach (string n in asm.GetManifestResourceNames())
            {
                if (n.EndsWith(resName, StringComparison.OrdinalIgnoreCase)) { match = n; break; }
            }
            if (match == null) return null;
            using (Stream stream = asm.GetManifestResourceStream(match))
            {
                if (stream == null) return null;
                using (MemoryStream ms = new MemoryStream())
                {
                    stream.CopyTo(ms);
                    return ms.ToArray();
                }
            }
        }

        static string HashBytes(byte[] data)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(data));
        }

        // Stamp = FileVersion EXE + SHA256 tong cac resource. Thieu/khac stamp -> doi chieu va ghi lai file khac hash.
        // Stamp khop -> chi tao lai file thieu/rong (khong ghi de ban sua tay hoac ban do updater tai ve).
        static void EnsureResources(string coreDir)
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            int count = EmbeddedResources.Length;
            byte[][] data = new byte[count][];
            string[] hashes = new string[count];
            StringBuilder all = new StringBuilder();
            for (int i = 0; i < count; i++)
            {
                data[i] = ReadResource(asm, EmbeddedResources[i]);
                hashes[i] = data[i] == null ? "-" : HashBytes(data[i]);
                all.Append(EmbeddedResources[i]).Append(':').Append(hashes[i]).Append('\n');
            }
            string stamp = CurrentFileVersion() + "\n" + HashBytes(Encoding.UTF8.GetBytes(all.ToString()));
            string stampPath = Path.Combine(coreDir, ".resources-stamp");
            string existing = null;
            if (File.Exists(stampPath))
            {
                try { existing = File.ReadAllText(stampPath).Replace("\r", "").Trim(); }
                catch (IOException stampError) { Log("Khong doc duoc stamp: " + stampError.Message); }
            }
            bool stale = existing != stamp;
            Log("Resource stamp " + (stale ? "thieu/khac -> doi chieu lai" : "khop"));
            // core\version.txt moi hon EXE: updater da nang cap script, khong ghi de bang ban nhung cu hon.
            bool updaterNewer = false;
            if (stale)
            {
                string versionTxt = Path.Combine(coreDir, "version.txt");
                Version scriptVersion, exeVersion;
                Version fileVersion;
                if (File.Exists(versionTxt) && Version.TryParse(File.ReadAllText(versionTxt).Trim(), out scriptVersion) &&
                    Version.TryParse(CurrentFileVersion(), out fileVersion))
                {
                    exeVersion = new Version(fileVersion.Major, fileVersion.Minor, Math.Max(fileVersion.Build, 0));
                    scriptVersion = new Version(scriptVersion.Major, Math.Max(scriptVersion.Minor, 0), Math.Max(scriptVersion.Build, 0));
                    if (scriptVersion > exeVersion)
                    {
                        updaterNewer = true;
                        Log("core\\version.txt (" + scriptVersion + ") moi hon EXE (" + exeVersion + "): khong ghi de script da co, chi tao file thieu/rong.");
                    }
                }
            }
            for (int i = 0; i < count; i++)
            {
                if (data[i] == null) continue;
                string target = ResourceTargetPath(coreDir, EmbeddedResources[i]);
                string targetDir = Path.GetDirectoryName(target);
                if (!Directory.Exists(targetDir)) Directory.CreateDirectory(targetDir);
                bool write;
                if (!File.Exists(target) || new FileInfo(target).Length == 0) write = true;
                else write = stale && !updaterNewer && Hash(target) != hashes[i];
                if (!write) continue;
                WriteAtomic(target, data[i]);
                Log("Da ghi resource: " + target);
            }
            if (stale && !updaterNewer) WriteAtomic(stampPath, Encoding.UTF8.GetBytes(stamp + "\n"));
        }

        // Ban cap nhat loi khoi dong: danh dau de updater.ps1 khong tai lai dung phien ban do.
        static void MarkUpdateFailed(string updDir)
        {
            try
            {
                string versionFile = Path.Combine(updDir, "files", "core", "version.txt");
                Version parsed;
                if (!File.Exists(versionFile) || !Version.TryParse(File.ReadAllText(versionFile).Trim(), out parsed))
                {
                    Log("Khong xac dinh duoc phien ban de danh dau loi (thieu/hong " + versionFile + ").");
                    return;
                }
                string flag = Path.Combine(updDir, "failed-" + parsed.ToString() + ".flag");
                File.WriteAllText(flag, DateTime.Now.ToString("o"));
                Log("Da danh dau phien ban loi: " + flag);
            }
            catch (Exception ex)
            {
                Log("Khong ghi duoc flag phien ban loi: " + ex.Message);
            }
        }

        static FileStream updateLock;

        static void AcquireUpdateLock(string updDir)
        {
            if (updateLock != null) return;
            Directory.CreateDirectory(updDir);
            updateLock = new FileStream(Path.Combine(updDir, "transaction.lock"), FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None);
        }

        static string SafePath(string root, string rel)
        {
            rel = rel.Replace('/', '\\');
            if (String.IsNullOrWhiteSpace(rel) || Path.IsPathRooted(rel) || rel.IndexOf(':') >= 0 ||
                rel.IndexOfAny(new char[] { '\t', '\r', '\n' }) >= 0)
                throw new IOException("Duong dan update khong hop le: " + rel);
            foreach (string part in rel.Split('\\'))
                if (part.Length == 0 || part == "." || part == ".." || part.TrimEnd(' ', '.') != part ||
                    part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    System.Text.RegularExpressions.Regex.IsMatch(part, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    throw new IOException("Duong dan update khong hop le: " + rel);
            if (!(rel.StartsWith("core\\", StringComparison.OrdinalIgnoreCase) ||
                  rel.StartsWith("tools\\", StringComparison.OrdinalIgnoreCase) ||
                  rel.Equals("Kid-FB.Y.exe", StringComparison.OrdinalIgnoreCase)) ||
                rel.Equals("core\\_update", StringComparison.OrdinalIgnoreCase) ||
                rel.Equals("core\\_backup", StringComparison.OrdinalIgnoreCase) ||
                rel.StartsWith("core\\_update\\", StringComparison.OrdinalIgnoreCase) ||
                rel.StartsWith("core\\_backup\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("Duong dan update khong duoc phep: " + rel);
            string full = Path.GetFullPath(Path.Combine(root, rel));
            for (string item = full; item != null && item.Length >= Path.GetFullPath(root).TrimEnd('\\').Length;
                 item = Path.GetDirectoryName(item))
                if ((File.Exists(item) || Directory.Exists(item)) &&
                    (File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Update khong ho tro lien ket: " + item);
            return full;
        }

        static string Hash(string path)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
            using (var file = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(file));
        }

        static string HashText(string text)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(text)));
        }

        static void CheckAvailableSpace(long required, long available)
        {
            if (available < required)
                throw new IOException("Khong du dung luong de sao luu va cap nhat. Can toi thieu " +
                    ((required + 1048575) / 1048576) + " MB trong; hien co " + (available / 1048576) +
                    " MB. Hay giai phong dung luong roi khoi dong lai; ban hien tai chua bi thay doi.");
        }

        static void EnsureUpdateSpace(string baseDir, string stage, System.Collections.Generic.List<string> list)
        {
            long required = 4 * 1024 * 1024; // Journal, filesystem metadata and bounded rounding reserve.
            foreach (string rel in list)
            {
                string dst = SafePath(baseDir, rel);
                checked
                {
                    if (File.Exists(dst)) required += new FileInfo(dst).Length;
                    required += new FileInfo(SafePath(stage, rel)).Length;
                }
            }
            string driveRoot = Path.GetPathRoot(Path.GetFullPath(baseDir));
            // DriveInfo does not support UNC shares; actual write failures still fail closed.
            if (!driveRoot.StartsWith(@"\\", StringComparison.Ordinal))
                CheckAvailableSpace(required, new DriveInfo(driveRoot).AvailableFreeSpace);
        }

        static void DurableText(string path, string text)
        {
            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                byte[] data = System.Text.Encoding.UTF8.GetBytes(text);
                file.Write(data, 0, data.Length);
                file.Flush(true);
            }
        }

        static string ReadToken(string backup)
        {
            string tokenFile = Path.Combine(backup, "TOKEN");
            if (!File.Exists(tokenFile)) throw new RecoveryException("Thiếu file TOKEN: " + tokenFile);
            string token;
            try { token = File.ReadAllText(tokenFile).Trim(); }
            catch (IOException ex) { throw new RecoveryException("Không đọc được file TOKEN: " + tokenFile, ex); }
            Guid value;
            if (!Guid.TryParseExact(token, "N", out value)) throw new RecoveryException("File TOKEN bị hỏng: " + tokenFile);
            return token;
        }

        static bool BootConfirmed(string updDir, string backup)
        {
            string token = ReadToken(backup);
            string boot = Path.Combine(updDir, "BOOT_OK");
            try { return File.Exists(boot) && File.ReadAllText(boot).Trim() == token; }
            catch (IOException) { return false; } // GUI may still hold its short write handle.
        }

        static bool RecoverPending(string baseDir, string updDir)
        {
            string backup = Path.Combine(baseDir, "core", "_backup");
            if (!File.Exists(Path.Combine(backup, "JOURNAL"))) return false;
            if (!BootConfirmed(updDir, backup))
            {
                Log("Giao dich cap nhat dang cho nhung chua co BOOT_OK; khoi phuc ban cu.");
                MarkUpdateFailed(updDir);
                RestoreBackup(baseDir, backup);
            }
            FinishTransaction(updDir, backup);
            return true;
        }

        static void FinishTransaction(string updDir, string backup)
        {
            // Delete READY before retiring the journal: a crash here remains recoverable.
            string ready = Path.Combine(updDir, "READY");
            if (File.Exists(ready)) File.Delete(ready);
            File.Delete(Path.Combine(backup, "JOURNAL"));
            // Backups and running .old executables may remain until the next transaction.
        }

        static bool ApplyUpdate(string baseDir, string updDir, out string backupDir)
        {
            backupDir = null;
            AcquireUpdateLock(updDir);
            if (RecoverPending(baseDir, updDir)) return false;
            string ready = Path.Combine(updDir, "READY");
            string stage = Path.Combine(updDir, "files");
            if (!File.Exists(ready) || !Directory.Exists(stage)) return false;
            var paths = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var list = new System.Collections.Generic.List<string>();
            foreach (string line in File.ReadAllLines(ready))
            {
                string rel = line.Trim().Replace('/', '\\');
                SafePath(baseDir, rel);
                if (!File.Exists(SafePath(stage, rel))) throw new IOException("Thieu file update: " + rel);
                if (paths.Add(rel) && !rel.Equals("core\\version.txt", StringComparison.OrdinalIgnoreCase)) list.Add(rel);
            }
            if (!paths.Contains("core\\version.txt")) throw new IOException("Thieu version trong READY.");
            list.Add("core\\version.txt"); // Always install and restore version last.
            Version nextVersion, currentVersion;
            string stagedVersion = SafePath(stage, "core\\version.txt");
            string localVersion = SafePath(baseDir, "core\\version.txt");
            if (!Version.TryParse(File.ReadAllText(stagedVersion).Trim(), out nextVersion) ||
                (File.Exists(localVersion) && Version.TryParse(File.ReadAllText(localVersion).Trim(), out currentVersion) && nextVersion <= currentVersion))
            { File.Delete(ready); return false; }

            EnsureUpdateSpace(baseDir, stage, list);
            backupDir = Path.Combine(baseDir, "core", "_backup");
            // No installation has begun if JOURNAL is absent.
            if (Directory.Exists(backupDir)) Directory.Delete(backupDir, true);
            Directory.CreateDirectory(backupDir);
            var journal = new System.Text.StringBuilder();
            foreach (string rel in list)
            {
                string dst = SafePath(baseDir, rel), bak = SafePath(backupDir, rel);
                if (File.Exists(dst))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(bak));
                    File.Copy(dst, bak, false);
                    using (var file = new FileStream(bak, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) file.Flush(true);
                    string hash = Hash(bak);
                    if (hash != Hash(dst)) throw new IOException("File thay doi trong luc sao luu: " + rel);
                    journal.Append("E\t" + hash + "\t" + rel + "\n");
                }
                else journal.Append("N\t-\t" + rel + "\n");
            }
            File.Delete(Path.Combine(updDir, "BOOT_OK"));
            DurableText(Path.Combine(backupDir, "TOKEN"), Guid.NewGuid().ToString("N"));
            string body = journal.ToString();
            DurableText(Path.Combine(backupDir, "JOURNAL.tmp"), "KIDFBY-JOURNAL-1\t" + HashText(body) + "\n" + body);
            File.Move(Path.Combine(backupDir, "JOURNAL.tmp"), Path.Combine(backupDir, "JOURNAL"));
            try
            {
                foreach (string rel in list)
                {
                    string dst = SafePath(baseDir, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    if (rel.Equals("Kid-FB.Y.exe", StringComparison.OrdinalIgnoreCase))
                        ReplaceExecutable(SafePath(stage, rel), dst);
                    else CopyWithRetry(SafePath(stage, rel), dst);
                    if (Hash(dst) != Hash(SafePath(stage, rel))) throw new IOException("Kiem tra update that bai: " + rel);
                }
                return true; // Retain READY, stage and journal until BOOT_OK.
            }
            catch (Exception installError)
            {
                try { RestoreBackup(baseDir, backupDir); FinishTransaction(updDir, backupDir); }
                catch (Exception restoreError)
                { throw new IOException("Update va khoi phuc that bai. Khong khoi chay bo file chua nhat quan. " + installError.Message + " / " + restoreError.Message, restoreError); }
                throw new IOException("Update that bai; da kiem tra khoi phuc ban cu. " + installError.Message, installError);
            }
        }

        static void ReplaceExecutable(string src, string dst)
        {
            string candidate = dst + ".candidate." + Guid.NewGuid().ToString("N");
            try
            {
                File.Copy(src, candidate, false);
                using (var file = new FileStream(candidate, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) file.Flush(true);
                if (Hash(candidate) != Hash(src)) throw new IOException("Kiem tra EXE that bai.");
                // Same-directory ReplaceFile keeps the canonical launcher present across interruption.
                // A running image remains at the unique backup path until its process exits.
                if (File.Exists(dst)) File.Replace(candidate, dst, dst + ".old." + Guid.NewGuid().ToString("N"), true);
                else File.Move(candidate, dst);
            }
            finally
            {
                // The candidate is never the only recovery copy. Keep .old files for running images.
                try { if (File.Exists(candidate)) File.Delete(candidate); } catch { }
            }
        }

        static void CopyWithRetry(string src, string dst)
        {
            for (int i = 0; ; i++)
            {
                try
                {
                    File.Copy(src, dst, true);
                    using (var file = new FileStream(dst, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) file.Flush(true);
                    return;
                }
                catch (IOException) { if (i >= 20) throw; System.Threading.Thread.Sleep(500); }
            }
        }

        static void RestoreBackup(string baseDir, string backupDir)
        {
            if (backupDir == null) throw new RecoveryException("Thiếu thư mục phục hồi core\\_backup.");
            string journalFile = Path.Combine(backupDir, "JOURNAL");
            if (!File.Exists(journalFile)) throw new RecoveryException("Thiếu file JOURNAL: " + journalFile);
            string journal = File.ReadAllText(journalFile);
            int separator = journal.IndexOf('\n');
            if (separator < 0 || journal.Substring(0, separator) != "KIDFBY-JOURNAL-1\t" + HashText(journal.Substring(separator + 1)))
                throw new RecoveryException("File JOURNAL bị hỏng (sai mã kiểm tra): " + journalFile);
            string[] lines = journal.Substring(separator + 1).Split(new char[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            var entries = new System.Collections.Generic.List<string[]>();
            foreach (string line in lines)
            {
                string[] entry = line.Split('\t');
                if (entry.Length != 3 || (entry[0] != "E" && entry[0] != "N")) throw new RecoveryException("File JOURNAL bị hỏng (dòng sai định dạng): " + journalFile);
                SafePath(baseDir, entry[2]);
                if (entry[0] == "E")
                {
                    string saved = SafePath(backupDir, entry[2]);
                    if (!File.Exists(saved)) throw new RecoveryException("Thiếu bản sao lưu: " + saved);
                    if (Hash(saved) != entry[1]) throw new RecoveryException("Bản sao lưu bị hỏng: " + saved);
                }
                entries.Add(entry);
            }
            if (entries.Count == 0) throw new RecoveryException("File JOURNAL rỗng: " + journalFile);
            entries.Sort(delegate(string[] a, string[] b) {
                return (a[2].Equals("core\\version.txt", StringComparison.OrdinalIgnoreCase) ? 1 : 0).CompareTo(
                    b[2].Equals("core\\version.txt", StringComparison.OrdinalIgnoreCase) ? 1 : 0);
            });
            foreach (string[] entry in entries)
            {
                string dst = SafePath(baseDir, entry[2]);
                if (entry[0] == "N")
                {
                    if (File.Exists(dst)) File.Delete(dst);
                    if (File.Exists(dst)) throw new IOException("Khong xoa duoc file moi: " + dst);
                }
                else
                {
                    if (File.Exists(dst) && Hash(dst) == entry[1]) continue;
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    if (entry[2].Equals("Kid-FB.Y.exe", StringComparison.OrdinalIgnoreCase))
                        ReplaceExecutable(SafePath(backupDir, entry[2]), dst);
                    else CopyWithRetry(SafePath(backupDir, entry[2]), dst);
                    if (Hash(dst) != entry[1]) throw new IOException("Kiem tra khoi phuc that bai: " + dst);
                }
            }
        }
    }
}
