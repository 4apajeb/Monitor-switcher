using System;
using System.Collections.Generic;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace MonitorSwitcher
{
    /// <summary>A monitor connected to this PC.</summary>
    public class MonitorInfo
    {
        /// <summary>PnP id from the EDID, e.g. AUS25BA — the Mac identifies monitors by it.</summary>
        public string Id { get; set; }
        public string Name { get; set; }
        public int Input { get; set; } = -1;
        public bool Ddc { get; set; }
        public string Device { get; set; }

        public string InputText => Ddc ? Inputs.Name(Input) : "no DDC";
        public string Detail => Id + (string.IsNullOrEmpty(Device) ? "" : " · " + Device);
    }

    public static class Inputs
    {
        public static string Name(int value)
        {
            switch (value)
            {
                case 1: return "VGA";
                case 3: return "DVI";
                case 15: return "DisplayPort 1";
                case 16: return "DisplayPort 2";
                case 17: return "HDMI 1";
                case 18: return "HDMI 2";
                case 27: return "USB-C";
                default: return value < 0 ? "—" : "code " + value;
            }
        }
    }

    /// <summary>DDC/CI over the GPU's own connection (dxva2.dll).</summary>
    public static class Ddc
    {
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MONITORINFOEX
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PHYSICAL_MONITOR
        {
            public IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
        }

        delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll")]
        static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

        [DllImport("dxva2.dll", SetLastError = true)]
        static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

        [DllImport("dxva2.dll", SetLastError = true)]
        static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

        [DllImport("dxva2.dll", SetLastError = true)]
        static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] monitors);

        [DllImport("dxva2.dll", SetLastError = true)]
        static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);

        [DllImport("dxva2.dll", SetLastError = true)]
        static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, IntPtr type, out uint current, out uint maximum);

        [DllImport("user32.dll")]
        static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

        const byte InputSourceVcp = 0x60;
        static readonly object Gate = new object();

        /// <summary>Calls <paramref name="action"/> for every physical monitor; return false to stop.</summary>
        static void ForEach(Func<MonitorInfo, IntPtr, bool> action)
        {
            var handles = new List<IntPtr>();
            MonitorEnumProc proc = (h, dc, r, d) => { handles.Add(h); return true; };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
            GC.KeepAlive(proc);

            foreach (var hmon in handles)
            {
                var info = new MONITORINFOEX { cbSize = Marshal.SizeOf(typeof(MONITORINFOEX)) };
                if (!GetMonitorInfo(hmon, ref info)) continue;

                var ids = new List<string>();
                for (uint i = 0; ; i++)
                {
                    var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)) };
                    if (!EnumDisplayDevices(info.szDevice, i, ref dd, 0)) break;
                    ids.Add(dd.DeviceID ?? "");
                }

                uint count;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, out count) || count == 0) continue;
                var physical = new PHYSICAL_MONITOR[count];
                if (!GetPhysicalMonitorsFromHMONITOR(hmon, count, physical)) continue;
                try
                {
                    for (int i = 0; i < count; i++)
                    {
                        // DeviceID looks like MONITOR\AUS25BA\{4d36e96e-...}\0003
                        string deviceId = i < ids.Count ? ids[i] : (ids.Count > 0 ? ids[0] : "");
                        string[] parts = deviceId.Split('\\');
                        var monitor = new MonitorInfo
                        {
                            Id = parts.Length > 1 ? parts[1].ToUpperInvariant() : "",
                            Name = physical[i].szPhysicalMonitorDescription,
                            Device = info.szDevice.Replace(@"\\.\", ""),
                        };
                        if (!action(monitor, physical[i].hPhysicalMonitor)) return;
                    }
                }
                finally
                {
                    DestroyPhysicalMonitors(count, physical);
                }
            }
        }

        public static List<MonitorInfo> List()
        {
            lock (Gate)
            {
                var names = FriendlyNames();
                var list = new List<MonitorInfo>();
                ForEach((m, handle) =>
                {
                    uint current, maximum;
                    m.Ddc = GetVCPFeatureAndVCPFeatureReply(handle, InputSourceVcp, IntPtr.Zero, out current, out maximum);
                    m.Input = m.Ddc ? (int)(current & 0xFF) : -1;
                    string friendly;
                    if (names.TryGetValue(m.Id, out friendly) && !string.IsNullOrEmpty(friendly)) m.Name = friendly;
                    list.Add(m);
                    return true;
                });
                return list;
            }
        }

        /// <summary>
        /// Sets the input source of the monitor with the given PnP id (or, failing that, the given
        /// EDID name — Samsungs report a different PnP id on each input). Returns "ok" or an error.
        /// </summary>
        public static string SetInput(string pnpId, string name, uint value)
        {
            lock (Gate)
            {
                string target = pnpId;
                if (!string.IsNullOrEmpty(name) && !List().Exists(m => string.Equals(m.Id, pnpId, StringComparison.OrdinalIgnoreCase)))
                {
                    var byName = List().Find(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase));
                    if (byName != null) target = byName.Id;
                }

                string result = "monitor " + pnpId + " not found";
                ForEach((m, handle) =>
                {
                    if (!string.Equals(m.Id, target, StringComparison.OrdinalIgnoreCase)) return true;
                    bool ok = false;
                    int error = 0;
                    for (int attempt = 0; attempt < 3 && !ok; attempt++)
                    {
                        ok = SetVCPFeature(handle, InputSourceVcp, value);
                        if (!ok) { error = Marshal.GetLastWin32Error(); Thread.Sleep(200); }
                    }
                    result = ok ? "ok" : "SetVCPFeature failed (error " + error + ")";
                    return false;
                });
                return result;
            }
        }

        /// <summary>Puts every display of this PC to sleep (monitors then fall back to another input).</summary>
        public static void DisplaysOff()
        {
            IntPtr result;
            SendMessageTimeout((IntPtr)0xFFFF, 0x0112 /* WM_SYSCOMMAND */, (IntPtr)0xF170 /* SC_MONITORPOWER */, (IntPtr)2, 0x0002, 1000, out result);
        }

        /// <summary>EDID model names (e.g. "XG259QN") keyed by PnP id, from WMI.</summary>
        static Dictionary<string, string> FriendlyNames()
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (var searcher = new ManagementObjectSearcher(@"root\wmi", "SELECT InstanceName, UserFriendlyName FROM WmiMonitorID"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        string instance = mo["InstanceName"] as string ?? ""; // DISPLAY\AUS25BA\5&...
                        string[] parts = instance.Split('\\');
                        if (parts.Length < 2) continue;
                        var raw = mo["UserFriendlyName"] as ushort[];
                        if (raw == null) continue;
                        var sb = new StringBuilder();
                        foreach (var ch in raw) { if (ch == 0) break; sb.Append((char)ch); }
                        map[parts[1]] = sb.ToString().Trim();
                    }
                }
            }
            catch
            {
                // WMI is optional — fall back to the generic description.
            }
            return map;
        }
    }
}
