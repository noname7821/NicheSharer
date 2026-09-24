using System;
using System.IO;
using System.Windows;

namespace NicheShareViewer;

// App entry, logs startup and crashes to startup.log next to the exe.
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        Log("start");
        DispatcherUnhandledException += (_, args) =>
        {
            Log("crash: " + args.Exception);
        };
        base.OnStartup(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Log($"exit {e.ApplicationExitCode}");
        base.OnExit(e);
    }

    private static void Log(string msg)
    {
        try
        {
            var dir = AppDomain.CurrentDomain.BaseDirectory;
            File.AppendAllText(Path.Combine(dir, "startup.log"),
                $"{DateTime.Now:T} {msg}{Environment.NewLine}");
        }
        catch { /* ignore */ }
    }
}
