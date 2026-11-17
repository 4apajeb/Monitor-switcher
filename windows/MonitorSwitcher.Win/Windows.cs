using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MonitorSwitcher
{
    /// <summary>Colors that follow the Windows light/dark setting, and XAML loading.</summary>
    public static class Theme
    {
        static readonly Dictionary<string, string> Dark = new Dictionary<string, string>
        {
            { "BG", "#1F1F1F" }, { "CARD", "#2A2A2A" }, { "ROW", "#333333" }, { "BORDER", "#383838" },
            { "TEXT", "#F3F3F3" }, { "SUB", "#A3A3A3" }, { "BTN", "#3A3A3A" }, { "BTNHOVER", "#474747" },
            { "ACCENT", "#4C8DFF" },
        };

        static readonly Dictionary<string, string> Light = new Dictionary<string, string>
        {
            { "BG", "#F3F3F3" }, { "CARD", "#FFFFFF" }, { "ROW", "#F4F5F7" }, { "BORDER", "#E3E3E3" },
            { "TEXT", "#1B1B1B" }, { "SUB", "#666666" }, { "BTN", "#ECECEC" }, { "BTNHOVER", "#E0E0E0" },
            { "ACCENT", "#2F6FED" },
        };

        public static bool IsDark
        {
            get
            {
                try
                {
                    using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                        return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
                }
                catch { return false; }
            }
        }

        static Dictionary<string, string> Palette => IsDark ? Dark : Light;

        public static Brush Brush(string key)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(Palette[key]));
            brush.Freeze();
            return brush;
        }

        public static Brush Gradient(string mode)
        {
            var brush = mode == "pc"
                ? new LinearGradientBrush(Color.FromRgb(0x85, 0x4D, 0xFF), Color.FromRgb(0xF2, 0x5E, 0xAD), 45)
                : new LinearGradientBrush(Color.FromRgb(0x29, 0x80, 0xFF), Color.FromRgb(0x4D, 0xC7, 0xFF), 45);
            brush.Freeze();
            return brush;
        }

        public static FrameworkElement Load(string resource)
        {
            string xaml;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
            using (var reader = new StreamReader(stream))
                xaml = reader.ReadToEnd();
            foreach (var pair in Palette) xaml = xaml.Replace("{" + pair.Key + "}", pair.Value);
            return (FrameworkElement)XamlReader.Parse(xaml);
        }

        public static ImageSource AppIcon()
        {
            try
            {
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico"))
                {
                    var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    return decoder.Frames.OrderByDescending(f => f.PixelWidth).First();
                }
            }
            catch { return null; }
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static void Style(Window window)
        {
            window.Icon = AppIcon();
            window.SourceInitialized += (s, e) =>
            {
                try
                {
                    int dark = IsDark ? 1 : 0;
                    DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 20 /* immersive dark mode */, ref dark, sizeof(int));
                }
                catch { }
            };
        }
    }

    public class MainWindow : Window
    {
        readonly Core core;
        readonly FrameworkElement root;
        readonly TextBox logBox;
        bool updatingChecks;

        T Find<T>(string name) where T : class => root.FindName(name) as T;

        public MainWindow(Core core, Action quit)
        {
            this.core = core;
            Title = "Monitor Switcher";
            Width = 860;
            Height = 760;
            MinWidth = 640;
            MinHeight = 520;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            UseLayoutRounding = true;
            Background = Theme.Brush("BG");
            Theme.Style(this);

            root = Theme.Load("MainWindow.xaml");
            Content = root;
            logBox = Find<TextBox>("LogBox");

            Find<Button>("MacCard").Click += (s, e) => { if (core.Mode != "mac") core.RequestSwitch("mac"); };
            Find<Button>("PcCard").Click += (s, e) => { if (core.Mode != "pc") core.RequestSwitch("pc"); };
            Find<Button>("CheckMacBtn").Click += (s, e) => core.CheckMacAsync();
            Find<Button>("UnpairBtn").Click += (s, e) =>
            {
                if (MessageBox.Show(this, "Unpair the Mac \u201c" + core.Settings.MacName + "\u201d? To pair again, find this PC from the Mac.",
                        "Monitor Switcher", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    core.Unpair();
            };
            Find<Button>("RefreshBtn").Click += (s, e) => core.RefreshMonitorsAsync();
            Find<Button>("UpdateBtn").Click += (s, e) => { if (core.UpdateAvailable != null) core.InstallUpdate(); else core.CheckForUpdatesAsync(); };
            Find<Button>("OpenLogBtn").Click += (s, e) => { try { Process.Start("explorer.exe", "\"" + Core.DataDir + "\""); } catch { } };
            Find<Button>("UninstallBtn").Click += (s, e) =>
            {
                if (MessageBox.Show(this, "Remove Monitor Switcher from this PC? Autostart, the Start menu shortcut and settings will be removed.",
                        "Monitor Switcher", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                core.Unpair();
                Installer.Uninstall();
                quit();
            };

            var autostart = Find<CheckBox>("AutostartBox");
            autostart.Checked += (s, e) => SetAutostart(true);
            autostart.Unchecked += (s, e) => SetAutostart(false);
            var autoUpdate = Find<CheckBox>("AutoUpdateBox");
            autoUpdate.Checked += (s, e) => { if (!updatingChecks) { core.Settings.AutoUpdate = true; core.SaveSettings(); } };
            autoUpdate.Unchecked += (s, e) => { if (!updatingChecks) { core.Settings.AutoUpdate = false; core.SaveSettings(); } };
            var input = Find<CheckBox>("InputBox");
            input.Checked += (s, e) => { if (!updatingChecks) { core.Settings.SwitchOnPcInput = true; core.SaveSettings(); } };
            input.Unchecked += (s, e) => { if (!updatingChecks) { core.Settings.SwitchOnPcInput = false; core.SaveSettings(); } };

            logBox.Text = string.Join(Environment.NewLine, core.LogLines());
            logBox.ScrollToEnd();

            core.Changed += Refresh;
            core.LogAdded += AppendLog;
            Closed += (s, e) => { core.Changed -= Refresh; core.LogAdded -= AppendLog; };
            Activated += (s, e) => core.CheckMacAsync();
            Refresh();
        }

        void SetAutostart(bool enabled)
        {
            if (updatingChecks) return;
            core.Settings.Autostart = enabled;
            try { Installer.SetAutostart(enabled); } catch (Exception ex) { core.Log("Autostart: " + ex.Message); }
            core.SaveSettings();
        }

        void AppendLog(string line)
        {
            logBox.AppendText((logBox.Text.Length > 0 ? Environment.NewLine : "") + line);
            logBox.ScrollToEnd();
        }

        void Refresh()
        {
            var s = core.Settings;
            string mode = core.Mode;

            Find<TextBlock>("HeaderStatus").Text =
                (mode == "pc" ? "This PC has the monitors" : mode == "mac" ? "The Mac has the monitors" : "Not sure who has the monitors")
                + " · " + Environment.MachineName;

            StyleModeCard("MacCard", "MacCheck", "MacCardSub", "mac", mode, s.IsPaired);
            StyleModeCard("PcCard", "PcCheck", "PcCardSub", "pc", mode, s.IsPaired);

            var dot = Find<Ellipse>("MacDot");
            var text = Find<TextBlock>("MacText");
            var hint = Find<TextBlock>("MacHint");
            if (!s.IsPaired)
            {
                dot.Fill = Brushes.Orange;
                text.Text = "No Mac paired yet";
                hint.Text = "On the Mac, open Monitor Switcher → PC → Find PCs and confirm the request here. " +
                            "If Windows Firewall asks, allow access on private networks.";
            }
            else
            {
                dot.Fill = core.MacOnline ? Brushes.LimeGreen : Brushes.IndianRed;
                text.Text = (s.MacName ?? "Mac") + " · " + s.MacHost + (core.MacOnline ? " · online" : " · not answering");
                hint.Text = core.MacOnline ? "" : (core.MacError ?? "");
            }
            Find<FrameworkElement>("MacButtons").Visibility = s.IsPaired ? Visibility.Visible : Visibility.Collapsed;

            var list = Find<ItemsControl>("MonitorList");
            list.ItemsSource = core.Monitors.ToList();
            Find<TextBlock>("NoMonitors").Visibility = core.Monitors.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

            updatingChecks = true;
            Find<CheckBox>("AutostartBox").IsChecked = s.Autostart;
            Find<CheckBox>("InputBox").IsChecked = s.SwitchOnPcInput;
            Find<CheckBox>("AutoUpdateBox").IsChecked = s.AutoUpdate;
            updatingChecks = false;

            Find<TextBlock>("VersionText").Text = "Version " + Core.Version;
            Find<TextBlock>("UpdateText").Text = core.UpdateStatus.Length > 0 ? core.UpdateStatus : "Checks GitHub for new versions automatically";
            var updateBtn = Find<Button>("UpdateBtn");
            updateBtn.Content = core.Updating ? "Installing…" : core.UpdateAvailable != null ? "Update to " + core.UpdateAvailable.Version : "Check now";
            updateBtn.IsEnabled = !core.Updating;
            var addresses = Core.LocalAddresses();
            Find<TextBlock>("NetInfo").Text = "This PC: " + Environment.MachineName +
                (addresses.Count > 0 ? " · " + string.Join(", ", addresses) : "") + " · port " + Core.PcPort + " · version " + Core.Version;
        }

        void StyleModeCard(string cardName, string checkName, string subName, string cardMode, string mode, bool paired)
        {
            var card = Find<Button>(cardName);
            bool active = mode == cardMode;
            card.Background = active ? Theme.Gradient(cardMode) : Theme.Brush("CARD");
            card.BorderBrush = active ? Brushes.Transparent : Theme.Brush("BORDER");
            card.Foreground = active ? Brushes.White : Theme.Brush("TEXT");
            card.IsEnabled = paired && !core.Busy;
            card.Opacity = paired ? 1 : 0.6;
            Find<TextBlock>(checkName).Visibility = active ? Visibility.Visible : Visibility.Hidden;
            Find<TextBlock>(subName).Text = active ? "Has the monitors" : core.Busy ? "Switching…" : "Click to hand the monitors over";
        }
    }

    /// <summary>"A Mac wants to pair" confirmation, shown on top of everything.</summary>
    public class PairDialog : Window
    {
        bool approved;

        PairDialog(string macName, string macHost)
        {
            Title = "Monitor Switcher";
            SizeToContent = SizeToContent.WidthAndHeight;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;
            Background = Theme.Brush("BG");
            Theme.Style(this);

            var root = Theme.Load("PairDialog.xaml");
            Content = root;
            ((TextBlock)root.FindName("Message")).Text =
                "The Mac \u201c" + macName + "\u201d (" + macHost + ") wants to switch monitors through this PC. Allow it only if it's your Mac.";
            ((Button)root.FindName("AllowBtn")).Click += (s, e) => { approved = true; Close(); };
            ((Button)root.FindName("DenyBtn")).Click += (s, e) => Close();

            // The Mac gives up after 90 s; close a little earlier.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(85) };
            timer.Tick += (s, e) => { timer.Stop(); Close(); };
            timer.Start();
            Loaded += (s, e) => { Activate(); System.Media.SystemSounds.Asterisk.Play(); };
        }

        public static bool Ask(string macName, string macHost)
        {
            var dialog = new PairDialog(macName, macHost);
            dialog.ShowDialog();
            return dialog.approved;
        }
    }
}
