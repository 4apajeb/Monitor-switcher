using System;
using System.Linq;
using System.Threading;
using System.Windows;

namespace MonitorSwitcher
{
    public static class Program
    {
        public const string QuitEventName = "MonitorSwitcher.Win.Quit";
        const string MutexName = "MonitorSwitcher.Win.SingleInstance";
        const string ShowEventName = "MonitorSwitcher.Win.Show";

        [STAThread]
        public static void Main(string[] args)
        {
            // Started from Downloads: install into %LOCALAPPDATA%\Programs and run that copy.
            if (!args.Contains("--portable") && Installer.InstallAndRelaunch()) return;

            bool createdNew;
            Mutex mutex = null;
            for (int attempt = 0; attempt < 20; attempt++)
            {
                mutex = new Mutex(true, MutexName, out createdNew);
                if (createdNew) break;
                if (!args.Contains("--installed"))
                {
                    // Already running: bring its window to the front instead.
                    try { using (var show = EventWaitHandle.OpenExisting(ShowEventName)) show.Set(); } catch { }
                    return;
                }
                // Freshly installed copy: wait for the old instance to quit.
                mutex.Dispose();
                mutex = null;
                Thread.Sleep(250);
            }
            if (mutex == null) return;

            using (var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName))
            using (var quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEventName))
            {
                var app = new App(showEvent, quitEvent, background: args.Contains("--background"));
                app.Run();
            }
            GC.KeepAlive(mutex);
        }
    }

    public class App : Application
    {
        readonly EventWaitHandle showEvent;
        readonly EventWaitHandle quitEvent;
        readonly bool background;
        Core core;
        Tray tray;
        MainWindow window;

        public App(EventWaitHandle showEvent, EventWaitHandle quitEvent, bool background)
        {
            this.showEvent = showEvent;
            this.quitEvent = quitEvent;
            this.background = background;
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += (s, ex) =>
            {
                core?.Log("Помилка: " + ex.Exception.Message);
                ex.Handled = true;
            };

            core = new Core(Dispatcher);
            core.ApprovePairing = (name, host) => PairDialog.Ask(name, host);
            if (core.Settings.Autostart)
            {
                try { Installer.SetAutostart(true); } catch { }
            }
            core.Start();

            tray = new Tray(core, ShowMainWindow, Quit);

            new Thread(() =>
            {
                var handles = new WaitHandle[] { showEvent, quitEvent };
                while (true)
                {
                    int which = WaitHandle.WaitAny(handles);
                    if (which == 0) Dispatcher.BeginInvoke(new Action(ShowMainWindow));
                    else { Dispatcher.BeginInvoke(new Action(Quit)); return; }
                }
            }) { IsBackground = true }.Start();

            if (!background) ShowMainWindow();
        }

        public void ShowMainWindow()
        {
            if (window == null)
            {
                window = new MainWindow(core, () => Quit());
                window.Closed += (s, e) => window = null;
            }
            window.Show();
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            window.Activate();
            window.Topmost = true;
            window.Topmost = false;
            window.Focus();
        }

        public void Quit()
        {
            tray?.Dispose();
            core?.Stop();
            Shutdown();
        }
    }
}
