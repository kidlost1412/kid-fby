using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]
[assembly: AssemblyInformationalVersion("2.0.0")]

namespace KidFBY
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string updDir = Path.Combine(baseDir, "core", "_update");
                AcquireUpdateLock(updDir);
                RecoverPending(baseDir, updDir);

                string coreDir = Path.Combine(baseDir, "core");
                if (!Directory.Exists(coreDir))
                {
                    Directory.CreateDirectory(coreDir);
                }

                string guiFile = Path.Combine(coreDir, "kid-fby-gui.ps1");
                string engineFile = Path.Combine(coreDir, "kid-fby.ps1");
                string languageFile = Path.Combine(coreDir, "whisper-language.ps1");
                string linkFile = Path.Combine(coreDir, "facebook-links.ps1");
                string fixFile = Path.Combine(coreDir, "fix-ket-noi.ps1");
                string icoFile = Path.Combine(coreDir, "Kid-FB.Y.ico");

                // Tu dong giai nen script neu chua co o thu muc core
                ExtractResourceIfMissing("kid-fby-gui.ps1", guiFile);
                ExtractResourceIfMissing("kid-fby.ps1", engineFile);
                ExtractResourceIfMissing("whisper-language.ps1", languageFile);
                ExtractResourceIfMissing("facebook-links.ps1", linkFile);
                ExtractResourceIfMissing("fix-ket-noi.ps1", fixFile);
                ExtractResourceIfMissing("Kid-FB.Y.ico", icoFile);
                ExtractResourceIfMissing("kid-logo.zip", Path.Combine(coreDir, "kid-logo.zip"));

                if (!File.Exists(guiFile))
                {
                    MessageBox.Show("Khong tim thay file khoi chay giao dien:\n" + guiFile,
                        "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                // Ap dung ban cap nhat da tai san (neu co)
                string backupDir = null;
                bool applied = ApplyUpdate(baseDir, updDir, out backupDir);

                Process proc = LaunchGui(guiFile, baseDir, args);

                if (applied && backupDir != null)
                {
                    // Cho GUI moi bao BOOT_OK; neu chet som / qua 45s khong bao -> rollback
                    bool ok = false;
                    for (int i = 0; i < 90; i++)
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
                        try { if (!proc.HasExited) proc.Kill(); } catch { }
                        if (!proc.HasExited && !proc.WaitForExit(10000))
                            throw new IOException("Khong dung duoc GUI de khoi phuc. Du lieu phuc hoi van duoc giu lai.");
                        RestoreBackup(baseDir, backupDir);
                        FinishTransaction(updDir, backupDir);
                        MessageBox.Show("Ban cap nhat moi khong khoi dong duoc.\nDa tu dong khoi phuc ban cu.",
                            "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        proc = LaunchGui(guiFile, baseDir, args);
                    }
                    else FinishTransaction(updDir, backupDir);
                }

                if (args != null && args.Length > 0 && Array.IndexOf(args, "-SelfTest") >= 0)
                {
                    proc.WaitForExit();
                    Environment.ExitCode = proc.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Environment.ExitCode = 1;
                MessageBox.Show("Loi khoi dong Kid FB.Y:\n\n" + ex.Message,
                    "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                if (updateLock != null) { updateLock.Dispose(); updateLock = null; }
            }
        }

        static Process LaunchGui(string guiFile, string baseDir, string[] args)
        {
            string arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + guiFile + "\"";
            if (args != null && args.Length > 0) arguments += " " + string.Join(" ", args);
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = arguments;
            psi.WorkingDirectory = baseDir;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.EnvironmentVariables.Remove("KID_FBY_UPDATE_TOKEN");
            string pendingBackup = Path.Combine(baseDir, "core", "_backup");
            if (File.Exists(Path.Combine(pendingBackup, "JOURNAL")))
                psi.EnvironmentVariables["KID_FBY_UPDATE_TOKEN"] = ReadToken(pendingBackup);
            return Process.Start(psi);
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
            string token = File.ReadAllText(Path.Combine(backup, "TOKEN")).Trim();
            Guid value;
            if (!Guid.TryParseExact(token, "N", out value)) throw new IOException("Token phuc hoi bi hong.");
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
            if (!BootConfirmed(updDir, backup)) RestoreBackup(baseDir, backup);
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
            if (backupDir == null) throw new IOException("Thieu thu muc phuc hoi.");
            string journal = File.ReadAllText(Path.Combine(backupDir, "JOURNAL"));
            int separator = journal.IndexOf('\n');
            if (separator < 0 || journal.Substring(0, separator) != "KIDFBY-JOURNAL-1\t" + HashText(journal.Substring(separator + 1)))
                throw new IOException("Journal phuc hoi bi hong; giu nguyen du lieu de kiem tra, khong khoi chay.");
            string[] lines = journal.Substring(separator + 1).Split(new char[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            var entries = new System.Collections.Generic.List<string[]>();
            foreach (string line in lines)
            {
                string[] entry = line.Split('\t');
                if (entry.Length != 3 || (entry[0] != "E" && entry[0] != "N")) throw new IOException("Journal phuc hoi bi hong.");
                SafePath(baseDir, entry[2]);
                if (entry[0] == "E" && Hash(SafePath(backupDir, entry[2])) != entry[1]) throw new IOException("Ban sao luu bi hong: " + entry[2]);
                entries.Add(entry);
            }
            if (entries.Count == 0) throw new IOException("Journal phuc hoi rong.");
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

        static void ExtractResourceIfMissing(string resName, string targetPath)
        {
            if (File.Exists(targetPath)) return;

            Assembly asm = Assembly.GetExecutingAssembly();
            string[] names = asm.GetManifestResourceNames();
            string match = null;
            foreach (string n in names)
            {
                if (n.EndsWith(resName, StringComparison.OrdinalIgnoreCase))
                {
                    match = n;
                    break;
                }
            }

            if (match == null) return;

            using (Stream stream = asm.GetManifestResourceStream(match))
            {
                if (stream == null) return;
                using (FileStream fs = new FileStream(targetPath, FileMode.Create, FileAccess.Write))
                {
                    stream.CopyTo(fs);
                }
            }
        }
    }
}
