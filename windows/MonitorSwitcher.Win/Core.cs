using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Threading;

namespace MonitorSwitcher
{
    public class Settings
    {
        public string MacName { get; set; }
        public string MacHost { get; set; }
        public int MacPort { get; set; } = 47801;
        public string Token { get; set; }
        public bool Autostart { get; set; } = true;
        /// <summary>Give the monitors to this PC as soon as its keyboard/mouse is used.</summary>
        public bool SwitchOnPcInput { get; set; } = true;

        [ScriptIgnore]
        public bool IsPaired => !string.IsNullOrEmpty(Token) && !string.IsNullOrEmpty(MacHost);
    }

    /// <summary>App state and logic shared by the window, tray icon and network server.</summary>
    public class Core
    {
        public const int PcPort = 47800;
        public const string Version = "1.0.0";

        public static readonly string DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MonitorSwitcher");
        static readonly string SettingsPath = Path.Combine(DataDir, "settings.json");
        static readonly string LogPath = Path.Combine(DataDir, "log.txt");

        readonly Dispatcher ui;
        readonly object logGate = new object();
        readonly List<string> logLines = new List<string>();
        Server server;
        Timer pollTimer;
        DateTime modeSyncedAt = DateTime.MinValue;
        DateTime lastInputReport = DateTime.MinValue;
        DateTime suppressInputUntil = DateTime.MinValue;

        public Settings Settings { get; private set; }
        public List<MonitorInfo> Monitors { get; private set; } = new List<MonitorInfo>();
        /// <summary>"mac", "pc" or "?" — who owns the monitors, as last reported by the Mac.</summary>
        public string Mode { get; private set; } = "?";
        public bool MacOnline { get; private set; }
        public string MacError { get; private set; }
        public bool Busy { get; private set; }

        /// <summary>Raised on the UI thread whenever something visible changed.</summary>
        public event Action Changed;
        public event Action<string> LogAdded;
        /// <summary>Asks the user to approve a Mac. Runs on the UI thread; returns true to pair.</summary>
        public Func<string, string, bool> ApprovePairing;

        public Core(Dispatcher ui)
        {
            this.ui = ui;
            Directory.CreateDirectory(DataDir);
            Settings = LoadSettings();
        }

        public void Start()
        {
            TrimLogFile();
            Log("Monitor Switcher " + Version + " запущено на " + Environment.MachineName);
            server = new Server(this);
            server.Start();
            RefreshMonitorsAsync();
            pollTimer = new Timer(_ => PollMac(), null, 1500, 15000);
            new Thread(WatchInput) { IsBackground = true, Name = "input-watch" }.Start();
        }

        public void Stop()
        {
            pollTimer?.Dispose();
            server?.Stop();
        }

        // ---------------------------------------------------------------- settings

        static Settings LoadSettings()
        {
            try
            {
                if (File.Exists(SettingsPath))
                    return new JavaScriptSerializer().Deserialize<Settings>(File.ReadAllText(SettingsPath, Encoding.UTF8)) ?? new Settings();
            }
            catch { }
            return new Settings();
        }

        public void SaveSettings()
        {
            try { File.WriteAllText(SettingsPath, new JavaScriptSerializer().Serialize(Settings), Encoding.UTF8); }
            catch (Exception ex) { Log("Не вдалося зберегти налаштування: " + ex.Message); }
            RaiseChanged();
        }

        public static string NewToken()
        {
            var bytes = new byte[18];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return Convert.ToBase64String(bytes).Replace('+', 'a').Replace('/', 'b').TrimEnd('=');
        }

        // ---------------------------------------------------------------- pairing

        public bool AskPairing(string macName, string macHost)
        {
            Log("Mac «" + macName + "» (" + macHost + ") просить підключення");
            bool approved = false;
            try
            {
                approved = (bool)ui.Invoke(new Func<bool>(() => ApprovePairing != null && ApprovePairing(macName, macHost)));
            }
            catch (Exception ex) { Log("Помилка діалогу: " + ex.Message); }
            Log(approved ? "Підключення дозволено" : "Підключення відхилено");
            return approved;
        }

        public void SetPairing(string macName, string macHost, int macPort, string token)
        {
            Settings.MacName = macName;
            Settings.MacHost = macHost;
            Settings.MacPort = macPort;
            Settings.Token = token;
            SaveSettings();
            MacOnline = true;
            RaiseChanged();
        }

        public void ClearPairing(string reason)
        {
            Settings.MacName = null;
            Settings.MacHost = null;
            Settings.Token = null;
            SaveSettings();
            MacOnline = false;
            Mode = "?";
            Log(reason);
            RaiseChanged();
        }

        public void Unpair()
        {
            if (!Settings.IsPaired) return;
            ThreadPool.QueueUserWorkItem(_ => CallMac("/unpair", null, 2000));
            ClearPairing("Mac від'єднано");
        }

        /// <summary>The Mac reached us from a new address (DHCP) — remember it.</summary>
        public void TouchMac(string host)
        {
            MacOnline = true;
            if (Settings.MacHost != host)
            {
                Log("Нова адреса Mac: " + host);
                Settings.MacHost = host;
                SaveSettings();
            }
        }

        // ---------------------------------------------------------------- monitors & mode

        public void RefreshMonitorsAsync()
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try { SetMonitors(Ddc.List()); }
                catch (Exception ex) { Log("Не вдалося прочитати монітори: " + ex.Message); }
            });
        }

        public void SetMonitors(List<MonitorInfo> monitors)
        {
            Monitors = monitors;
            RaiseChanged();
        }

        public void SetMode(string mode, string source)
        {
            if (mode != "mac" && mode != "pc") mode = "?";
            modeSyncedAt = DateTime.UtcNow;
            if (Mode == mode) return;
            Mode = mode;
            Log("Монітори тепер у " + (mode == "pc" ? "ПК" : mode == "mac" ? "Mac" : "?") + " (" + source + ")");
            RaiseChanged();
        }

        /// <summary>Manual switch from this PC (tray or window). The Mac does the actual work.</summary>
        public void RequestSwitch(string mode)
        {
            if (!Settings.IsPaired) { Log("Спершу підключіть Mac"); return; }
            if (mode == "mac") suppressInputUntil = DateTime.UtcNow.AddSeconds(60);
            Busy = true;
            RaiseChanged();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var reply = CallMac("/switch", new Dictionary<string, string> { { "mode", mode } }, 8000);
                if (reply != null)
                {
                    Log("Mac перемикає монітори на " + (mode == "pc" ? "ПК" : "Mac"));
                    ApplyMacReply(reply);
                }
                Busy = false;
                RaiseChanged();
            });
        }

        void PollMac()
        {
            if (!Settings.IsPaired) return;
            var reply = CallMac("/status", null, 3000);
            if (reply != null) ApplyMacReply(reply);
        }

        public void CheckMacAsync() => ThreadPool.QueueUserWorkItem(_ => PollMac());

        void ApplyMacReply(Dictionary<string, object> reply)
        {
            object mode;
            if (reply.TryGetValue("mode", out mode)) SetMode(mode as string, "Mac");
            object name;
            if (reply.TryGetValue("name", out name) && name is string s && s.Length > 0 && s != Settings.MacName)
            {
                Settings.MacName = s;
                SaveSettings();
            }
        }

        // ---------------------------------------------------------------- user input on this PC

        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        void WatchInput()
        {
            var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
            GetLastInputInfo(ref info);
            uint last = info.dwTime;
            while (true)
            {
                Thread.Sleep(250);
                if (!GetLastInputInfo(ref info) || info.dwTime == last) continue;
                last = info.dwTime;
                try { OnUserInput(); } catch { }
            }
        }

        /// <summary>
        /// Someone is using this PC's keyboard or mouse. A keyboard that merely fell asleep never
        /// talks to the PC, so this is a reliable "the user came to the PC" signal.
        /// </summary>
        void OnUserInput()
        {
            if (!Settings.SwitchOnPcInput || !Settings.IsPaired) return;
            var now = DateTime.UtcNow;
            if (now < suppressInputUntil) return;
            if (Mode == "pc" && (now - modeSyncedAt).TotalSeconds < 20) return;
            if ((now - lastInputReport).TotalSeconds < 2) return;
            lastInputReport = now;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var reply = CallMac("/pc-input", null, 4000);
                if (reply == null) return;
                object switched;
                if (reply.TryGetValue("switched", out switched) && switched is bool b && b)
                    Log("Ви за ПК — Mac віддає монітори");
                ApplyMacReply(reply);
            });
        }

        // ---------------------------------------------------------------- talking to the Mac

        public Dictionary<string, object> CallMac(string path, Dictionary<string, string> query, int timeoutMs)
        {
            var s = Settings;
            if (!s.IsPaired) return null;
            var sb = new StringBuilder("http://").Append(s.MacHost).Append(':').Append(s.MacPort).Append(path)
                .Append("?token=").Append(Uri.EscapeDataString(s.Token));
            if (query != null)
                foreach (var kv in query) sb.Append('&').Append(kv.Key).Append('=').Append(Uri.EscapeDataString(kv.Value));

            try
            {
                var request = (HttpWebRequest)WebRequest.Create(sb.ToString());
                request.Timeout = timeoutMs;
                request.ReadWriteTimeout = timeoutMs;
                request.Proxy = null;
                request.KeepAlive = false;
                using (var response = (HttpWebResponse)request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    var reply = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                    SetMacOnline(true, null);
                    return reply;
                }
            }
            catch (WebException ex) when (ex.Response is HttpWebResponse r && r.StatusCode == HttpStatusCode.Forbidden)
            {
                SetMacOnline(false, "Mac більше не впізнає цей ПК — підключіть заново");
                return null;
            }
            catch (Exception ex)
            {
                SetMacOnline(false, ex.Message);
                return null;
            }
        }

        void SetMacOnline(bool online, string error)
        {
            if (MacOnline == online && MacError == error) return;
            bool changed = MacOnline != online;
            MacOnline = online;
            MacError = error;
            if (changed) Log(online ? "Зв'язок з Mac є" : "Mac не відповідає: " + error);
            RaiseChanged();
        }

        // ---------------------------------------------------------------- misc

        public static List<string> LocalAddresses()
        {
            try
            {
                return Dns.GetHostEntry(Dns.GetHostName()).AddressList
                    .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
                    .Select(a => a.ToString())
                    .Where(a => !a.StartsWith("169.254."))
                    .ToList();
            }
            catch { return new List<string>(); }
        }

        public void Log(string message)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + message;
            lock (logGate)
            {
                logLines.Add(line);
                if (logLines.Count > 400) logLines.RemoveRange(0, logLines.Count - 400);
                try { File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd ") + line + Environment.NewLine, Encoding.UTF8); } catch { }
            }
            try { ui.BeginInvoke(new Action(() => LogAdded?.Invoke(line))); } catch { }
        }

        public List<string> LogLines()
        {
            lock (logGate) return new List<string>(logLines);
        }

        static void TrimLogFile()
        {
            try
            {
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > 1_000_000)
                {
                    var lines = File.ReadAllLines(LogPath);
                    File.WriteAllLines(LogPath, lines.Skip(lines.Length / 2));
                }
            }
            catch { }
        }

        void RaiseChanged()
        {
            try { ui.BeginInvoke(new Action(() => Changed?.Invoke())); } catch { }
        }
    }
}
