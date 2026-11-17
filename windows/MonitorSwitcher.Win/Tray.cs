using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

namespace MonitorSwitcher
{
    /// <summary>The notification-area icon: always there, even when the window is closed.</summary>
    public class Tray : IDisposable
    {
        readonly Core core;
        readonly NotifyIcon icon;
        readonly ToolStripMenuItem toPc;
        readonly ToolStripMenuItem toMac;
        readonly ToolStripMenuItem autostart;
        readonly ToolStripMenuItem status;
        readonly ToolStripMenuItem update;
        string notifiedVersion;

        public Tray(Core core, Action open, Action quit)
        {
            this.core = core;

            var menu = new ContextMenuStrip { ShowImageMargin = false };
            var openItem = new ToolStripMenuItem("Open Monitor Switcher", null, (s, e) => open());
            openItem.Font = new Font(openItem.Font, System.Drawing.FontStyle.Bold);
            status = new ToolStripMenuItem("") { Enabled = false };
            toPc = new ToolStripMenuItem("Monitors → PC", null, (s, e) => core.RequestSwitch("pc"));
            toMac = new ToolStripMenuItem("Monitors → Mac", null, (s, e) => core.RequestSwitch("mac"));
            update = new ToolStripMenuItem("", null, (s, e) => core.InstallUpdate()) { Visible = false };
            autostart = new ToolStripMenuItem("Start with Windows", null, (s, e) =>
            {
                core.Settings.Autostart = !core.Settings.Autostart;
                try { Installer.SetAutostart(core.Settings.Autostart); } catch { }
                core.SaveSettings();
            });
            menu.Items.AddRange(new ToolStripItem[]
            {
                openItem, status, update, new ToolStripSeparator(), toPc, toMac, new ToolStripSeparator(), autostart,
                new ToolStripSeparator(), new ToolStripMenuItem("Quit", null, (s, e) => quit()),
            });
            menu.Opening += (s, e) => Refresh();

            icon = new NotifyIcon
            {
                Icon = LoadIcon(),
                ContextMenuStrip = menu,
                Visible = true,
            };
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) open(); };
            icon.BalloonTipClicked += (s, e) => core.InstallUpdate();

            core.Changed += Refresh;
            Refresh();
        }

        static Icon LoadIcon()
        {
            try
            {
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico"))
                    return new Icon(stream, SystemInformation.SmallIconSize);
            }
            catch { return SystemIcons.Application; }
        }

        void Refresh()
        {
            string owner = core.Mode == "pc" ? "PC" : core.Mode == "mac" ? "Mac" : "—";
            string link = !core.Settings.IsPaired ? "no Mac paired" : core.MacOnline ? "Mac online" : "Mac not answering";
            status.Text = "Monitors: " + owner + " · " + link;
            string tip = "Monitor Switcher — monitors on the " + owner;
            icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            bool canSwitch = core.Settings.IsPaired && !core.Busy;
            toPc.Enabled = canSwitch && core.Mode != "pc";
            toMac.Enabled = canSwitch && core.Mode != "mac";
            autostart.Checked = core.Settings.Autostart;

            var release = core.UpdateAvailable;
            update.Visible = release != null;
            update.Enabled = !core.Updating;
            if (release != null)
            {
                update.Text = core.Updating ? "Installing " + release.Version + "…" : "Update to " + release.Version;
                if (notifiedVersion != release.Version && !core.Settings.AutoUpdate)
                {
                    notifiedVersion = release.Version;
                    icon.ShowBalloonTip(5000, "Monitor Switcher " + release.Version, "A new version is available. Click to update.", ToolTipIcon.Info);
                }
            }
        }

        public void Dispose()
        {
            core.Changed -= Refresh;
            icon.Visible = false;
            icon.Dispose();
        }
    }
}
