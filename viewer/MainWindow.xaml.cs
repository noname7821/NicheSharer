using System;
using System.IO;
using System.Linq;
using System.Net.Http;
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
        var ws = b.StartsWith("https", StringComparison.OrdinalIgnoreCase) ? "wss:" : "ws:";
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
            var res = await http.GetAsync(checkUrl);
            if (!res.IsSuccessStatusCode) { SetStatus(false, "No such room (expired?)"); Log($"room check: {checkUrl} -> {(int)res.StatusCode}"); return; }
            var info = JsonDocument.Parse(await res.Content.ReadAsStringAsync()).RootElement;
            if (!info.GetProperty("hasPhone").GetBoolean()) { SetStatus(false, "Phone not connected yet"); return; }

            // Open socket.
            _cts = new CancellationTokenSource();
            _ws = new ClientWebSocket();
            await _ws.ConnectAsync(new Uri(WsUrl(code)), _cts.Token);
            SetStatus(true, $"Connected to {code}");
            Log($"joined room {code}");
            ConnectBtn.Visibility = Visibility.Collapsed;
            LeaveBtn.Visibility = Visibility.Visible;
            Dispatcher.Invoke(() =>
            {
                _screen?.Close();
                _screen = new ScreenWindow(code);
                _screen.Closed += (_, _) => _screen = null;
                _screen.Clicked += (x, y) => SendInput($"{{\"t\":\"input\",\"kind\":\"tap\",\"x\":{x:F4},\"y\":{y:F4}}}");
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

    private void Leave(string text)
    {
        try { _ping?.Stop(); } catch { }
        try { _cts?.Cancel(); } catch { }
        try { _ws?.Abort(); } catch { }
        _ws = null;
        SetStatus(false, text);
        Dispatcher.Invoke(() =>
        {
            try { _screen?.Close(); } catch { }
            _screen = null;
            ConnectBtn.Visibility = Visibility.Visible;
            LeaveBtn.Visibility = Visibility.Collapsed;
        });
    }
}
