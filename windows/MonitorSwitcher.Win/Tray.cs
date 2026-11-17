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

        public Tray(Core core, Action open, Action quit)
        {
            this.core = core;

            var menu = new ContextMenuStrip { ShowImageMargin = false };
            var openItem = new ToolStripMenuItem("Відкрити Monitor Switcher", null, (s, e) => open());
            openItem.Font = new Font(openItem.Font, System.Drawing.FontStyle.Bold);
            status = new ToolStripMenuItem("") { Enabled = false };
            toPc = new ToolStripMenuItem("Монітори → ПК", null, (s, e) => core.RequestSwitch("pc"));
            toMac = new ToolStripMenuItem("Монітори → Mac", null, (s, e) => core.RequestSwitch("mac"));
            autostart = new ToolStripMenuItem("Запускати разом з Windows", null, (s, e) =>
            {
                core.Settings.Autostart = !core.Settings.Autostart;
                try { Installer.SetAutostart(core.Settings.Autostart); } catch { }
                core.SaveSettings();
            });
            menu.Items.AddRange(new ToolStripItem[]
            {
                openItem, status, new ToolStripSeparator(), toPc, toMac, new ToolStripSeparator(), autostart,
                new ToolStripSeparator(), new ToolStripMenuItem("Вийти", null, (s, e) => quit()),
            });
            menu.Opening += (s, e) => Refresh();

            icon = new NotifyIcon
            {
                Icon = LoadIcon(),
                ContextMenuStrip = menu,
                Visible = true,
            };
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) open(); };

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
            string owner = core.Mode == "pc" ? "ПК" : core.Mode == "mac" ? "Mac" : "—";
            string link = !core.Settings.IsPaired ? "Mac не підключено" : core.MacOnline ? "Mac на зв'язку" : "Mac не відповідає";
            status.Text = "Монітори: " + owner + " · " + link;
            string tip = "Monitor Switcher — монітори: " + owner;
            icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            bool canSwitch = core.Settings.IsPaired && !core.Busy;
            toPc.Enabled = canSwitch && core.Mode != "pc";
            toMac.Enabled = canSwitch && core.Mode != "mac";
            autostart.Checked = core.Settings.Autostart;
        }

        public void Dispose()
        {
            core.Changed -= Refresh;
            icon.Visible = false;
            icon.Dispose();
        }
    }
}
