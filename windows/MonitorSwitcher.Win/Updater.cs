using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

namespace MonitorSwitcher
{
    public class ReleaseInfo
    {
        public string Version;
        public string Notes;
        public string ExeUrl;
    }

    /// <summary>Self-update from GitHub Releases.</summary>
    public static class Updater
    {
        const string AssetName = "MonitorSwitcher.exe";

        /// <summary>"owner/repo" — stored as assembly metadata so forks update from their own releases.</summary>
        public static string Repository
        {
            get
            {
                var attribute = Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(AssemblyMetadataAttribute), false)
                    .OfType<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "UpdateRepository");
                return attribute?.Value ?? "4apajeb/Monitor-switcher";
            }
        }

        static Updater()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        }

        public static ReleaseInfo Latest()
        {
            var request = (HttpWebRequest)WebRequest.Create("https://api.github.com/repos/" + Repository + "/releases/latest");
            request.UserAgent = "MonitorSwitcher-Windows/" + Core.Version;
            request.Accept = "application/vnd.github+json";
            request.Timeout = 20000;
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                var release = new ReleaseInfo
                {
                    Version = ((json["tag_name"] as string) ?? "0").TrimStart('v', 'V'),
                    Notes = json.ContainsKey("body") ? json["body"] as string ?? "" : "",
                };
                if (json["assets"] is IEnumerable assets)
                {
                    foreach (var item in assets)
                    {
                        if (item is Dictionary<string, object> asset && asset["name"] as string == AssetName)
                            release.ExeUrl = asset["browser_download_url"] as string;
                    }
                }
                return release;
            }
        }

        public static bool IsNewer(string candidate, string installed)
        {
            int[] a = Numbers(candidate), b = Numbers(installed);
            for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
            {
                int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
                if (x != y) return x > y;
            }
            return false;
        }

        static int[] Numbers(string version) =>
            (version ?? "0").TrimStart('v', 'V').Split('.')
                .Select(p => { int n; return int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out n) ? n : 0; })
                .ToArray();

        /// <summary>
        /// Downloads the new exe and starts it. The new copy asks this one to quit, replaces the
        /// installed exe and starts itself in the tray.
        /// </summary>
        public static void DownloadAndRun(ReleaseInfo release)
        {
            if (string.IsNullOrEmpty(release.ExeUrl)) throw new InvalidOperationException("the release has no " + AssetName);
            string path = Path.Combine(Path.GetTempPath(), "MonitorSwitcher-" + release.Version + ".exe");
            var request = (HttpWebRequest)WebRequest.Create(release.ExeUrl);
            request.UserAgent = "MonitorSwitcher-Windows/" + Core.Version;
            request.Timeout = 120000;
            using (var response = request.GetResponse())
            using (var input = response.GetResponseStream())
            using (var output = File.Create(path))
                input.CopyTo(output);

            if (new FileInfo(path).Length < 10_000) throw new InvalidDataException("the download is too small");
            Process.Start(new ProcessStartInfo(path, "--update") { UseShellExecute = false });
        }
    }
}
