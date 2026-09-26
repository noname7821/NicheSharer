using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace NicheShareViewer;

// Extra window for the remote screen, like other remote tools.
public partial class ScreenWindow : Window
{
    public event Action<double, double>? Tapped;
    public event Action<double, double, double, double>? Swiped;
    public event Action<double, double, string>? Scrolled;
    public event Action? HomePressed;

    // Keep for old callers.
    public event Action<double, double>? Clicked
    {
        add { Tapped += value; }
        remove { }
    }

    private Point? _downPx;
    private double _downX, _downY;

    public ScreenWindow(string code)
    {
        InitializeComponent();
        Title = $"NicheShare Screen - {code}";
    }

    public void SetFrame(byte[] jpeg)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.StreamSource = new MemoryStream(jpeg);
            img.EndInit();
            img.Freeze();
            Dispatcher.BeginInvoke(() => ScreenImage.Source = img);
        }
        catch { /* drop bad frame */ }
    }

    private bool Map(Point p, out double x, out double y)
    {
        x = y = 0;
        var bmp = ScreenImage.Source as BitmapSource;
        if (bmp == null || bmp.PixelWidth <= 0) return false;
        double scale = Math.Min(ScreenImage.ActualWidth / bmp.PixelWidth, ScreenImage.ActualHeight / bmp.PixelHeight);
        if (scale <= 0) return false;
        double dw = bmp.PixelWidth * scale, dh = bmp.PixelHeight * scale;
        double ox = (ScreenImage.ActualWidth - dw) / 2, oy = (ScreenImage.ActualHeight - dh) / 2;
        x = (p.X - ox) / dw; y = (p.Y - oy) / dh;
        if (x < 0 || x > 1 || y < 0 || y > 1) return false;
        return true;
    }

    private void Screen_Down(object sender, MouseButtonEventArgs e)
    {
        ScreenImage.CaptureMouse();
        _downPx = e.GetPosition(ScreenImage);
        if (Map(_downPx.Value, out var x, out var y)) { _downX = x; _downY = y; }
        else { _downX = _downY = -1; }
    }

    private void Screen_Move(object sender, MouseEventArgs e)
    {
        // No live move stream, swipe resolves on release.
    }

    private void Screen_Up(object sender, MouseButtonEventArgs e)
    {
        try { ScreenImage.ReleaseMouseCapture(); } catch { }
        if (_downPx == null) return;
        var upPx = e.GetPosition(ScreenImage);
        if (!Map(upPx, out var x2, out var y2)) { _downPx = null; return; }
        if (_downX < 0) { _downPx = null; return; }
        var dx = upPx.X - _downPx.Value.X;
        var dy = upPx.Y - _downPx.Value.Y;
        _downPx = null;
        if (Math.Sqrt(dx * dx + dy * dy) < 8)
            Tapped?.Invoke(x2, y2);
        else
            Swiped?.Invoke(_downX, _downY, x2, y2);
    }

    private void Screen_Wheel(object sender, MouseWheelEventArgs e)
    {
        if (!Map(e.GetPosition(ScreenImage), out var x, out var y)) return;
        Scrolled?.Invoke(x, y, e.Delta > 0 ? "up" : "down");
    }

    private void Home_Click(object sender, RoutedEventArgs e) => HomePressed?.Invoke();
}
