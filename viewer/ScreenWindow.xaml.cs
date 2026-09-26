using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace NicheShareViewer;

// Extra window for the remote screen, like other remote tools.
public partial class ScreenWindow : Window
{
    public event Action<double, double>? Clicked;

    public ScreenWindow(string code)
    {
        InitializeComponent();
        Title = $"NicheShare Screen - {code}";
    }

    public void SetFrame(byte[] jpeg)
    {
        Dispatcher.Invoke(() =>
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.StreamSource = new MemoryStream(jpeg);
            img.EndInit();
            img.Freeze();
            ScreenImage.Source = img;
        });
    }

    private void Screen_Click(object sender, MouseButtonEventArgs e)
    {
        var bmp = ScreenImage.Source as BitmapSource;
        if (bmp == null || bmp.PixelWidth <= 0) return;
        // Uniform fit letterboxes: map into the real bitmap rect.
        double scale = Math.Min(ScreenImage.ActualWidth / bmp.PixelWidth, ScreenImage.ActualHeight / bmp.PixelHeight);
        double dw = bmp.PixelWidth * scale, dh = bmp.PixelHeight * scale;
        double ox = (ScreenImage.ActualWidth - dw) / 2, oy = (ScreenImage.ActualHeight - dh) / 2;
        var p = e.GetPosition(ScreenImage);
        double x = (p.X - ox) / dw, y = (p.Y - oy) / dh;
        if (x < 0 || x > 1 || y < 0 || y > 1) return;
        Clicked?.Invoke(x, y);
    }
}
