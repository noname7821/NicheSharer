using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace NicheShareViewer;

// PC side: join room by code, show frames, send taps and keys.
public partial class MainWindow : Window
{
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _cts;
    private System.Timers.Timer? _ping;
    private ScreenWindow? _screen;
    private TcpClient? _usb;
    private StreamReader? _usbReader;
    private StreamWriter? _usbWriter;
    private Process? _iproxy;

    public MainWindow()
    {
        InitializeComponent();
    }

    private void Log(string msg) =>
        Dispatcher.Invoke(() => LogBox.Items.Add($"[{DateTime.Now:T}] {msg}"));

    private void SetStatus(bool on, string text) => Dispatcher.Invoke(() =>
    {
        Dot.Fill = new SolidColorBrush(on ? Color.FromRgb(0x22, 0xC5, 0x5E) : Color.FromRgb(0x52, 0x52, 0x5B));
        StatusText.Text = text;
    });

    private string BaseUrl()
    {
        var b = ServerBox.Text.Trim().TrimEnd('/');
        if (!b.Contains("://")) b = "https://" + b;
        // Tolerate pasted page URLs: keep scheme + host only.
        try { return new Uri(b).GetLeftPart(UriPartial.Authority).TrimEnd('/'); }
        catch { return b; }
    }

    private string WsUrl(string code)
    {
        var b = BaseUrl();
        var ws = b.StartsWith("https", StringComparison.OrdinalIgnoreCase) ? "wss" : "ws";
        var idx = b.IndexOf(':');
        var rest = idx >= 0 ? b.Substring(idx) : "//" + b;
        return ws + rest + $"/ws?code={code}&role=pc";
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        var code = new string(CodeBox.Text.Trim().Where(char.IsDigit).ToArray());
        if (code.Length != 6) { SetStatus(false, "Code needs 6 digits"); return; }
        if (string.IsNullOrWhiteSpace(ServerBox.Text)) { SetStatus(false, "Enter server first"); return; }
        try
        {
            // Check room first.
            using var http = new HttpClient();
            var checkUrl = $"{BaseUrl()}/api/room/{code}";
            Log("room check: " + checkUrl);
            Uri checkUri;
            try { checkUri = new Uri(checkUrl); }
            catch (Exception ex) { SetStatus(false, "Bad server url: " + ex.Message); return; }
            var res = await http.GetAsync(checkUri);
            if (!res.IsSuccessStatusCode)
            {
                SetStatus(false, "No such room (expired?)");
                Log($"room check: {checkUrl} -> {(int)res.StatusCode}");
                try
                {
                    // Wrong server? The IPA site answers /api/ipas, signaling answers /api/room.
                    var probe = await http.GetAsync(new Uri(BaseUrl() + "/api/ipas"));
                    if (probe.IsSuccessStatusCode)
                        SetStatus(false, "Wrong server: this is the IPA site. Use the signaling server.");
                }
                catch { /* ignore */ }
                return;
            }
            var info = JsonDocument.Parse(await res.Content.ReadAsStringAsync()).RootElement;
            if (!info.GetProperty("hasPhone").GetBoolean()) { SetStatus(false, "Phone not connected yet"); return; }

            // Open socket.
            _cts = new CancellationTokenSource();
            _ws = new ClientWebSocket();
            var wsUrl = WsUrl(code);
            Log("ws url: " + wsUrl);
            Uri wsUri;
            try { wsUri = new Uri(wsUrl); }
            catch (Exception ex) { SetStatus(false, "Bad ws url: " + ex.Message); return; }
            await _ws.ConnectAsync(wsUri, _cts.Token);
            SetStatus(true, $"Connected to {code}");
            Log($"joined room {code}");
            ConnectBtn.Visibility = Visibility.Collapsed;
            UsbBtn.Visibility = Visibility.Collapsed;
            LeaveBtn.Visibility = Visibility.Visible;
            Dispatcher.Invoke(() =>
            {
                _screen?.Close();
                _screen = new ScreenWindow(code);
                _screen.Closed += (_, _) => _screen = null;
                _screen.Tapped += (x, y) => SendInput($"{{\"t\":\"input\",\"kind\":\"tap\",\"x\":{x.ToString("F4", CultureInfo.InvariantCulture)},\"y\":{y.ToString("F4", CultureInfo.InvariantCulture)}}}");
                _screen.Swiped += (x1, y1, x2, y2) => SendInput($"{{\"t\":\"input\",\"kind\":\"swipe\",\"x1\":{x1.ToString("F4", CultureInfo.InvariantCulture)},\"y1\":{y1.ToString("F4", CultureInfo.InvariantCulture)},\"x2\":{x2.ToString("F4", CultureInfo.InvariantCulture)},\"y2\":{y2.ToString("F4", CultureInfo.InvariantCulture)},\"ms\":280}}");
                _screen.Scrolled += (x, y, dir) => SendInput($"{{\"t\":\"input\",\"kind\":\"scroll\",\"x\":{x.ToString("F4", CultureInfo.InvariantCulture)},\"y\":{y.ToString("F4", CultureInfo.InvariantCulture)},\"dir\":\"{dir}\"}}");
                _screen.HomePressed += () => SendInput("{\"t\":\"input\",\"kind\":\"home\"}");
                _screen.Show();
            });

            // Keep alive.
            _ping = new System.Timers.Timer(25000);
            _ping.Elapsed += (_, _) => SendRaw("{\"t\":\"ping\"}");
            _ping.Start();

            _ = ReceiveLoop(_cts.Token);
        }
        catch (Exception ex) { SetStatus(false, "Connect failed: " + ex.Message); }
    }

    private async Task ReceiveLoop(CancellationToken token)
    {
        var buf = new byte[65536];
        try
        {
            while (_ws?.State == WebSocketState.Open && !token.IsCancellationRequested)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult r;
                do
                {
                    r = await _ws.ReceiveAsync(buf, token);
                    ms.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);
                if (r.MessageType != WebSocketMessageType.Text) continue;
                var text = Encoding.UTF8.GetString(ms.ToArray());
                try
                {
                    var msg = JsonDocument.Parse(text).RootElement;
                    var type = msg.GetProperty("t").GetString();
                    if (type == "status")
                        Dispatcher.Invoke(() => Log("phone status: " + msg.GetProperty("status").ToString()));
                    else if (type == "frame")
                    {
                        // Base64 jpeg -> extra screen window.
                        var bytes = Convert.FromBase64String(msg.GetProperty("data").GetString()!);
                        Dispatcher.Invoke(() => _screen?.SetFrame(bytes));
                    }
                }
                catch { /* ignore bad messages */ }
            }
        }
        catch { /* closed */ }
    }

    private void SendRaw(string json)
    {
        try
        {
            if (_ws?.State == WebSocketState.Open)
                _ = _ws.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch { /* ignore */ }
    }

    private void SendInput(string json)
    {
        SendRaw(json);
        Dispatcher.Invoke(() => Log("sent " + json));
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (_ws?.State != WebSocketState.Open || e.Source is System.Windows.Controls.TextBox) return;
        string? key = e.Key switch
        {
            Key.Enter => "Enter",
            Key.Back => "Backspace",
            Key.Space => " ",
            _ when e.Key >= Key.A && e.Key <= Key.Z => e.Key.ToString().ToLower(),
            _ when e.Key >= Key.D0 && e.Key <= Key.D9 => ((char)('0' + (e.Key - Key.D0))).ToString(),
            _ => null,
        };
        if (key != null) SendInput($"{{\"t\":\"input\",\"kind\":\"key\",\"key\":\"{key}\"}}");
    }

    private void Leave_Click(object sender, RoutedEventArgs e) => Leave("Not connected");

    // USB direct: iPhone USB -> bundled iproxy 18000 18000 -> 127.0.0.1:18000. No relay server.
    private async void UsbConnect_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CloseUsb();
            if (!await EnsureUsbTunnel()) { SetStatus(false, "USB: no phone (plug in via USB)"); return; }
            _usb = new TcpClient();
            await _usb.ConnectAsync("127.0.0.1", 18000);
            var ns = _usb.GetStream();
            _usbReader = new StreamReader(ns, Encoding.UTF8);
            _usbWriter = new StreamWriter(ns, Encoding.UTF8) { AutoFlush = true };
            SetStatus(true, "USB connected");
            Log("usb connected");
            ConnectBtn.Visibility = Visibility.Collapsed;
            UsbBtn.Visibility = Visibility.Collapsed;
            LeaveBtn.Visibility = Visibility.Visible;
            Dispatcher.Invoke(() =>
            {
                _screen?.Close();
                _screen = new ScreenWindow("USB");
                _screen.Closed += (_, _) => _screen = null;
                _screen.Tapped += (x, y) => SendUsb($"{{\"t\":\"input\",\"kind\":\"tap\",\"x\":{F(x)},\"y\":{F(y)}}}");
                _screen.Swiped += (x1, y1, x2, y2) => SendUsb($"{{\"t\":\"input\",\"kind\":\"swipe\",\"x1\":{F(x1)},\"y1\":{F(y1)},\"x2\":{F(x2)},\"y2\":{F(y2)},\"ms\":280}}");
                _screen.Scrolled += (x, y, dir) => SendUsb($"{{\"t\":\"input\",\"kind\":\"scroll\",\"x\":{F(x)},\"y\":{F(y)},\"dir\":\"{dir}\"}}");
                _screen.HomePressed += () => SendUsb("{\"t\":\"input\",\"kind\":\"home\"}");
                _screen.Show();
            });
            _ = UsbReceiveLoop();
        }
        catch (Exception ex)
        {
            SetStatus(false, "USB failed: " + ex.Message);
            Log("usb: plug phone in via USB");
        }
    }

    private static string F(double v) => v.ToString("F4", CultureInfo.InvariantCulture);

    // Starts bundled tools/iproxy/iproxy.exe unless the port is already open.
    private async Task<bool> EnsureUsbTunnel()
    {
        try
        {
            using var probe = new TcpClient();
            using var cts = new CancellationTokenSource(1500);
            await probe.ConnectAsync("127.0.0.1", 18000, cts.Token);
            Log("usb: tunnel already open");
            return true;
        }
        catch { /* start our own */ }
        try
        {
            var exe = Path.Combine(AppContext.BaseDirectory, "tools", "iproxy", "iproxy.exe");
            if (!File.Exists(exe)) { Log("usb: tools\\iproxy\\iproxy.exe missing"); return false; }
            try { _iproxy?.Kill(); } catch { }
            _iproxy = Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "18000 18000",
                CreateNoWindow = true,
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(exe)!,
            });
            Log("usb: iproxy started, waiting for phone...");
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(500);
                if (_iproxy?.HasExited == true) { Log("usb: iproxy exited, no phone?"); return false; }
                try
                {
                    using var probe = new TcpClient();
                    using var cts = new CancellationTokenSource(1000);
                    await probe.ConnectAsync("127.0.0.1", 18000, cts.Token);
                    return true;
                }
                catch { /* keep waiting */ }
            }
            Log("usb: no phone on 18000");
            return false;
        }
        catch (Exception ex) { Log("usb: iproxy start failed: " + ex.Message); return false; }
    }

    private void KillIproxy()
    {
        try
        {
            if (_iproxy != null && !_iproxy.HasExited) _iproxy.Kill();
        }
        catch { /* ignore */ }
        _iproxy = null;
    }

    private async Task UsbReceiveLoop()
    {
        try
        {
            string? line;
            while (_usbReader != null && (line = await _usbReader.ReadLineAsync()) != null)
            {
                try
                {
                    var msg = JsonDocument.Parse(line).RootElement;
                    var type = msg.GetProperty("t").GetString();
                    if (type == "frame")
                    {
                        var bytes = Convert.FromBase64String(msg.GetProperty("data").GetString()!);
                        Dispatcher.Invoke(() => _screen?.SetFrame(bytes));
                    }
                    else if (type == "hello")
                    {
                        Dispatcher.Invoke(() => Log("usb: phone hello"));
                    }
                }
                catch { /* ignore bad lines */ }
            }
        }
        catch { /* closed */ }
        if (_usb != null) Dispatcher.Invoke(() => Leave("USB closed"));
    }

    private void SendUsb(string json)
    {
        try { _usbWriter?.WriteLineAsync(json); } catch { /* ignore */ }
        Dispatcher.Invoke(() => Log("sent " + json));
    }

    private void CloseUsb()
    {
        try { _usbWriter?.Close(); } catch { }
        try { _usbReader?.Close(); } catch { }
        try { _usb?.Close(); } catch { }
        _usbWriter = null; _usbReader = null; _usb = null;
    }

    private void CopyLogs_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var lines = new System.Collections.Generic.List<string>();
            foreach (var item in LogBox.Items) lines.Add(item?.ToString() ?? "");
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
            Log("logs copied to clipboard");
        }
        catch { /* ignore */ }
    }

    private void Leave(string text)
    {
        try { _ping?.Stop(); } catch { }
        try { _cts?.Cancel(); } catch { }
        try { _ws?.Abort(); } catch { }
        _ws = null;
        CloseUsb();
        KillIproxy();
        SetStatus(false, text);
        Dispatcher.Invoke(() =>
        {
            try { _screen?.Close(); } catch { }
            _screen = null;
            ConnectBtn.Visibility = Visibility.Visible;
            UsbBtn.Visibility = Visibility.Visible;
            LeaveBtn.Visibility = Visibility.Collapsed;
        });
    }

    protected override void OnClosed(EventArgs e)
    {
        KillIproxy();
        CloseUsb();
        base.OnClosed(e);
    }
}
