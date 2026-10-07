using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

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
                // Don dep cac file .old con lai tu lan update truoc (neu co)
                try
                {
                    string oldExe = Path.Combine(baseDir, "Kid-FB.Y.exe.old");
                    if (File.Exists(oldExe)) File.Delete(oldExe);
                }
                catch { }

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

                if (!File.Exists(guiFile))
                {
                    MessageBox.Show("Khong tim thay file khoi chay giao dien:\n" + guiFile,
                        "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                // Ap dung ban cap nhat da tai san (neu co)
                string updDir = Path.Combine(coreDir, "_update");
                string backupDir = null;
                bool applied = ApplyUpdate(baseDir, updDir, out backupDir);

                Process proc = LaunchGui(guiFile, baseDir, args);

                if (applied && backupDir != null)
                {
                    // Cho GUI moi bao BOOT_OK; neu chet som / qua 45s khong bao -> rollback
                    string bootOk = Path.Combine(updDir, "BOOT_OK");
                    bool ok = false;
                    for (int i = 0; i < 90; i++)
                    {
                        if (File.Exists(bootOk)) { ok = true; break; }
                        if (proc.HasExited)
                        {
                            System.Threading.Thread.Sleep(300);
                            if (File.Exists(bootOk)) ok = true;
                            break;
                        }
                        System.Threading.Thread.Sleep(500);
                    }
                    if (!ok)
                    {
                        try { if (!proc.HasExited) proc.Kill(); } catch { }
                        RestoreBackup(baseDir, backupDir);
                        MessageBox.Show("Ban cap nhat moi khong khoi dong duoc.\nDa tu dong khoi phuc ban cu.",
                            "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        proc = LaunchGui(guiFile, baseDir, args);
                    }
                }

                if (args != null && args.Length > 0 && Array.IndexOf(args, "-SelfTest") >= 0)
                {
                    proc.WaitForExit();
                    Environment.ExitCode = proc.ExitCode;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Loi khoi dong Kid FB.Y:\n\n" + ex.Message,
                    "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            return Process.Start(psi);
        }

        // Doc core\_update\READY (danh sach file tuong doi), sao luu file cu, chep file moi tu core\_update\files
        static bool ApplyUpdate(string baseDir, string updDir, out string backupDir)
        {
            backupDir = null;
            string ready = Path.Combine(updDir, "READY");
            string stage = Path.Combine(updDir, "files");
            if (!File.Exists(ready) || !Directory.Exists(stage)) return false;

            // Bo qua goi cu con sot lai; khong ha phien ban khi mo ban moi.
            string stagedVersion = Path.Combine(stage, "core", "version.txt");
            string localVersion = Path.Combine(baseDir, "core", "version.txt");
            Version nextVersion;
            Version currentVersion;
            if (!File.Exists(stagedVersion) ||
                !Version.TryParse(File.ReadAllText(stagedVersion).Trim(), out nextVersion) ||
                (File.Exists(localVersion) &&
                 Version.TryParse(File.ReadAllText(localVersion).Trim(), out currentVersion) &&
                 nextVersion <= currentVersion))
            {
                File.Delete(ready);
                return false;
            }

            // File trung lap khong duoc ghi de ban sao luu cua chinh no.
            var paths = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var uniqueList = new System.Collections.Generic.List<string>();
            foreach (string line in File.ReadAllLines(ready))
            {
                string rel = line.Trim();
                if (rel.Length > 0 && paths.Add(rel)) uniqueList.Add(rel);
            }
            string[] list = uniqueList.ToArray();
            // Kiem tra du file truoc khi dong vao bat cu gi
            foreach (string rel in list)
            {
                if (rel.Trim().Length == 0) continue;
                if (rel.Contains("..") || Path.IsPathRooted(rel)) { File.Delete(ready); return false; }
                if (!File.Exists(Path.Combine(stage, rel))) { File.Delete(ready); return false; }
            }

            backupDir = Path.Combine(Path.Combine(baseDir, "core"), "_backup");
            if (Directory.Exists(backupDir)) Directory.Delete(backupDir, true);
            Directory.CreateDirectory(backupDir);

            // Doi GUI cu thoat han (toi da ~10s) roi moi chep
            System.Threading.Thread.Sleep(800);
            try
            {
                foreach (string rel in list)
                {
                    if (rel.Trim().Length == 0) continue;
                    string dst = Path.Combine(baseDir, rel);
                    string src = Path.Combine(stage, rel);
                    string bak = Path.Combine(backupDir, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(bak));
                    if (File.Exists(dst)) File.Copy(dst, bak, true);
                    else File.WriteAllText(bak + ".new", "");   // danh dau file moi, rollback se xoa
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    if (rel.Equals("Kid-FB.Y.exe", StringComparison.OrdinalIgnoreCase))
                    {
                        string oldExe = dst + ".old";
                        try { if (File.Exists(oldExe)) File.Delete(oldExe); } catch { }
                        if (File.Exists(dst)) File.Move(dst, oldExe);
                        CopyWithRetry(src, dst);
                    }
                    else
                    {
                        CopyWithRetry(src, dst);
                    }
                }
            }
            catch (Exception ex)
            {
                RestoreBackup(baseDir, backupDir);
                try { File.Delete(ready); } catch { }
                MessageBox.Show("Khong ap dung duoc ban cap nhat, da giu nguyen ban cu:\n\n" + ex.Message,
                    "Kid FB.Y", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                backupDir = null;
                return false;
            }

            try { File.Delete(ready); } catch { }
            try { Directory.Delete(stage, true); } catch { }
            try { File.Delete(Path.Combine(updDir, "BOOT_OK")); } catch { }
            return true;
        }

        static void CopyWithRetry(string src, string dst)
        {
            for (int i = 0; ; i++)
            {
                try { File.Copy(src, dst, true); return; }
                catch (IOException) { if (i >= 20) throw; System.Threading.Thread.Sleep(500); }
            }
        }

        static void RestoreBackup(string baseDir, string backupDir)
        {
            if (backupDir == null || !Directory.Exists(backupDir)) return;
            foreach (string bak in Directory.GetFiles(backupDir, "*", SearchOption.AllDirectories))
            {
                string rel = bak.Substring(backupDir.Length).TrimStart('\\', '/');
                try
                {
                    if (rel.EndsWith(".new"))
                    {
                        string added = Path.Combine(baseDir, rel.Substring(0, rel.Length - 4));
                        if (File.Exists(added)) File.Delete(added);
                    }
                    else
                    {
                        CopyWithRetry(bak, Path.Combine(baseDir, rel));
                    }
                }
                catch { }
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
