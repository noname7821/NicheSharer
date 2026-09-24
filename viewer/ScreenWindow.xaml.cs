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
        var p = e.GetPosition(ScreenImage);
        if (ScreenImage.ActualWidth <= 0 || ScreenImage.ActualHeight <= 0) return;
        var x = Math.Clamp(p.X / ScreenImage.ActualWidth, 0, 1);
        var y = Math.Clamp(p.Y / ScreenImage.ActualHeight, 0, 1);
        Clicked?.Invoke(x, y);
    }
}
