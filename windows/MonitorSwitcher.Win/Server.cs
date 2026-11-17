using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace MonitorSwitcher
{
    /// <summary>
    /// Tiny HTTP API (TCP 47800) the Mac uses to switch monitors through this PC, plus a UDP
    /// responder on the same port so the Mac can find this PC on the local network.
    /// </summary>
    public class Server
    {
        readonly Core core;
        TcpListener tcp;
        UdpClient udp;
        volatile bool running;

        public Server(Core core) { this.core = core; }

        public void Start()
        {
            running = true;
            try
            {
                tcp = new TcpListener(IPAddress.Any, Core.PcPort);
                tcp.Start();
                new Thread(AcceptLoop) { IsBackground = true, Name = "http" }.Start();
                core.Log("Чекаю на Mac на порту " + Core.PcPort);
            }
            catch (Exception ex)
            {
                core.Log("Не вдалося відкрити порт " + Core.PcPort + ": " + ex.Message);
            }

            try
            {
                udp = new UdpClient();
                udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                // Don't let ICMP "port unreachable" replies kill the receive loop.
                const int SIO_UDP_CONNRESET = -1744830452;
                udp.Client.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null);
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, Core.PcPort));
                new Thread(UdpLoop) { IsBackground = true, Name = "discovery" }.Start();
            }
            catch (Exception ex)
            {
                core.Log("Пошук у мережі недоступний: " + ex.Message);
            }
        }

        public void Stop()
        {
            running = false;
            try { tcp?.Stop(); } catch { }
            try { udp?.Close(); } catch { }
        }

        void UdpLoop()
        {
            while (running)
            {
                try
                {
                    var from = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = udp.Receive(ref from);
                    string text = Encoding.UTF8.GetString(data);
                    if (!text.StartsWith("MSW-DISCOVER")) continue;
                    string answer = string.Join("|", "MSW-PC", Environment.MachineName, Core.Version,
                        Core.PcPort.ToString(), core.Settings.IsPaired ? "paired" : "free");
                    byte[] reply = Encoding.UTF8.GetBytes(answer);
                    udp.Send(reply, reply.Length, from);
                }
                catch (Exception ex)
                {
                    if (!running) return;
                    core.Log("UDP: " + ex.Message);
                    Thread.Sleep(1000);
                }
            }
        }

        void AcceptLoop()
        {
            while (running)
            {
                TcpClient client;
                try { client = tcp.AcceptTcpClient(); }
                catch { if (!running) return; Thread.Sleep(200); continue; }
                ThreadPool.QueueUserWorkItem(_ => Handle(client));
            }
        }

        void Handle(TcpClient client)
        {
            using (client)
            {
                try
                {
                    client.ReceiveTimeout = 5000;
                    client.SendTimeout = 5000;
                    var stream = client.GetStream();
                    var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
                    string requestLine = reader.ReadLine();
                    if (string.IsNullOrEmpty(requestLine)) return;
                    string header;
                    while (!string.IsNullOrEmpty(header = reader.ReadLine())) { }

                    string[] parts = requestLine.Split(' ');
                    if (parts.Length < 2) return;
                    string target = parts[1], path = target, query = "";
                    int qi = target.IndexOf('?');
                    if (qi >= 0) { path = target.Substring(0, qi); query = target.Substring(qi + 1); }

                    var remote = ((IPEndPoint)client.Client.RemoteEndPoint).Address;
                    if (remote.IsIPv4MappedToIPv6) remote = remote.MapToIPv4();

                    int code = 200;
                    object result;
                    try { result = Route(path, ParseQuery(query), remote.ToString(), ref code); }
                    catch (Exception ex) { code = 500; result = Error(ex.Message); }
                    Write(stream, code, result);
                }
                catch (Exception ex)
                {
                    core.Log("HTTP: " + ex.Message);
                }
            }
        }

        object Route(string path, Dictionary<string, string> q, string remote, ref int code)
        {
            var settings = core.Settings;
            if (path == "/hello")
            {
                return new Dictionary<string, object>
                {
                    { "ok", true }, { "name", Environment.MachineName }, { "version", Core.Version },
                    { "paired", settings.IsPaired }, { "mac", settings.MacName ?? "" },
                };
            }

            if (path == "/pair")
            {
                string macName = Get(q, "mac", "Mac");
                int port;
                if (!int.TryParse(Get(q, "port", "47801"), out port)) port = 47801;
                if (!core.AskPairing(macName, remote)) return Error("підключення відхилено на ПК");
                string token = Core.NewToken();
                core.SetPairing(macName, remote, port, token);
                return new Dictionary<string, object> { { "ok", true }, { "token", token }, { "name", Environment.MachineName } };
            }

            if (!settings.IsPaired || Get(q, "token", "") != settings.Token)
            {
                code = 403;
                return Error("невірний токен");
            }
            core.TouchMac(remote);

            switch (path)
            {
                case "/status":
                {
                    var monitors = Ddc.List();
                    core.SetMonitors(monitors);
                    return new Dictionary<string, object>
                    {
                        { "ok", true }, { "name", Environment.MachineName }, { "version", Core.Version },
                        { "monitors", monitors.Select(m => new Dictionary<string, object>
                            { { "id", m.Id }, { "name", m.Name }, { "input", m.Input }, { "ddc", m.Ddc } }).ToList() },
                    };
                }
                case "/input":
                {
                    string id = Get(q, "monitor", "");
                    uint value;
                    if (!uint.TryParse(Get(q, "value", ""), out value)) return Error("невірне значення");
                    string result = Ddc.SetInput(id, Get(q, "name", ""), value);
                    core.Log(id + " → " + Inputs.Name((int)value) + (result == "ok" ? "" : ": " + result));
                    return new Dictionary<string, object> { { "ok", result == "ok" }, { "result", result } };
                }
                case "/displays-off":
                    Ddc.DisplaysOff();
                    core.Log("Екрани ПК вимкнено на прохання Mac");
                    return Ok();
                case "/mode":
                    core.SetMode(Get(q, "mode", "?"), Get(q, "reason", "Mac"));
                    return Ok();
                case "/log":
                    return new Dictionary<string, object> { { "ok", true }, { "lines", core.LogLines() } };
                case "/unpair":
                    core.ClearPairing("Mac від'єднав цей ПК");
                    return Ok();
                default:
                    code = 404;
                    return Error("невідомий запит");
            }
        }

        static Dictionary<string, object> Ok() => new Dictionary<string, object> { { "ok", true } };
        static Dictionary<string, object> Error(string message) =>
            new Dictionary<string, object> { { "ok", false }, { "error", message } };

        static string Get(Dictionary<string, string> q, string key, string fallback)
        {
            string value;
            return q.TryGetValue(key, out value) ? value : fallback;
        }

        static Dictionary<string, string> ParseQuery(string query)
        {
            var result = new Dictionary<string, string>();
            foreach (string pair in query.Split('&'))
            {
                if (pair.Length == 0) continue;
                int eq = pair.IndexOf('=');
                string key = Uri.UnescapeDataString((eq < 0 ? pair : pair.Substring(0, eq)).Replace('+', ' '));
                string value = eq < 0 ? "" : Uri.UnescapeDataString(pair.Substring(eq + 1).Replace('+', ' '));
                result[key] = value;
            }
            return result;
        }

        static void Write(Stream stream, int code, object body)
        {
            byte[] payload = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(body));
            string status = code == 200 ? "OK" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : "Error";
            string head = "HTTP/1.1 " + code + " " + status + "\r\n" +
                          "Content-Type: application/json; charset=utf-8\r\n" +
                          "Content-Length: " + payload.Length + "\r\n" +
                          "Connection: close\r\n\r\n";
            byte[] headBytes = Encoding.ASCII.GetBytes(head);
            stream.Write(headBytes, 0, headBytes.Length);
            stream.Write(payload, 0, payload.Length);
            stream.Flush();
        }
    }
}
