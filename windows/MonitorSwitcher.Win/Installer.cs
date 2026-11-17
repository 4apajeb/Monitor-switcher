using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using Microsoft.Win32;

namespace MonitorSwitcher
{
    /// <summary>Copies the exe to %LOCALAPPDATA%\Programs, adds a Start menu shortcut and autostart.</summary>
    public static class Installer
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunValue = "MonitorSwitcher";

        public static readonly string InstallDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "MonitorSwitcher");
        public static readonly string InstalledExe = Path.Combine(InstallDir, "MonitorSwitcher.exe");
        static readonly string ShortcutPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Monitor Switcher.lnk");

        public static string CurrentExe => Assembly.GetEntryAssembly().Location;

        public static bool IsInstalledCopy =>
            string.Equals(Path.GetFullPath(CurrentExe), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

        /// <summary>
        /// When started from Downloads (or anywhere else), install/update the copy in Programs,
        /// start it and return true so this process exits.
        /// </summary>
        public static bool InstallAndRelaunch(bool background)
        {
            if (IsInstalledCopy) return false;
            try
            {
                // Ask a running copy to quit so its exe can be replaced.
                try
                {
                    using (var quit = EventWaitHandle.OpenExisting(Program.QuitEventName))
                        quit.Set();
                }
                catch (WaitHandleCannotBeOpenedException) { }

                Directory.CreateDirectory(InstallDir);
                Exception last = null;
                for (int attempt = 0; attempt < 20; attempt++)
                {
                    try
                    {
                        File.Copy(CurrentExe, InstalledExe, true);
                        last = null;
                        break;
                    }
                    catch (Exception ex) { last = ex; Thread.Sleep(250); }
                }
                if (last != null) throw last;

                CreateShortcut();
                Process.Start(new ProcessStartInfo(InstalledExe, background ? "--installed --background" : "--installed") { UseShellExecute = true });
                return true;
            }
            catch
            {
                return false; // run from wherever we are
            }
        }

        public static void CreateShortcut()
        {
            try
            {
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(shellType);
                object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { ShortcutPath });
                Type linkType = link.GetType();
                linkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { InstalledExe });
                linkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { InstallDir });
                linkType.InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { "Monitor Switcher" });
                linkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            }
            catch { }
        }

        public static bool IsAutostartEnabled()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                return key?.GetValue(RunValue) != null;
        }

        public static void SetAutostart(bool enabled)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (enabled) key.SetValue(RunValue, "\"" + CurrentExe + "\" --background");
                else if (key.GetValue(RunValue) != null) key.DeleteValue(RunValue);
            }
        }

        /// <summary>Removes autostart and the shortcut, then deletes the program folder after exit.</summary>
        public static void Uninstall()
        {
            try { SetAutostart(false); } catch { }
            try { if (File.Exists(ShortcutPath)) File.Delete(ShortcutPath); } catch { }
            try
            {
                string script = "/c timeout /t 2 /nobreak >nul & rmdir /s /q \"" + InstallDir + "\" & rmdir /s /q \"" + Core.DataDir + "\"";
                Process.Start(new ProcessStartInfo("cmd.exe", script) { CreateNoWindow = true, UseShellExecute = false });
            }
            catch { }
        }
    }
}
