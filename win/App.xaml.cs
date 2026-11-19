using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;

namespace MacBridgeUI;

public static class OmniFlowPaths
{
    public static string AppDataDirectory
    {
        get
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OmniFlow");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string LogDirectory
    {
        get
        {
            string dir = Path.Combine(AppDataDirectory, "logs");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string RuntimeLogPath => Path.Combine(LogDirectory, "omniflow.log");
    public static string CrashLogPath => Path.Combine(LogDirectory, "crash.log");
    public static string TrustedPeersPath => Path.Combine(AppDataDirectory, "trusted_peers.json");

    public static void AppendCrashLog(string category, Exception ex)
    {
        string entry = $"[{DateTimeOffset.Now:O}] [{category}] {ex}{Environment.NewLine}{new string('-', 60)}{Environment.NewLine}";
        try
        {
            File.AppendAllText(CrashLogPath, entry);
        }
        catch
        {
            try
            {
                string fallback = Path.Combine(Path.GetTempPath(), "omniflow_crash.log");
                File.AppendAllText(fallback, entry);
            }
            catch { }
        }
    }
}

public partial class App : Application
{
    public static bool IsDropProxyMode { get; private set; }
    private int _recoverableUiErrorCount;
    private int _fatalHandlingStarted;

    protected override void OnStartup(StartupEventArgs e)
    {
        if (Array.Exists(e.Args, a => string.Equals(a, "--selftest", StringComparison.OrdinalIgnoreCase)))
        {
            int code = OmniFlowSelfTests.RunAll();
            Environment.Exit(code);
            return;
        }
        int proxyIdx = Array.FindIndex(e.Args, a => string.Equals(a, "--drop-proxy", StringComparison.OrdinalIgnoreCase));
        if (proxyIdx >= 0 && proxyIdx + 3 < e.Args.Length && int.TryParse(e.Args[proxyIdx + 1], out int parentPid))
        {
            IsDropProxyMode = true;
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            base.OnStartup(e);
            ElevatedDropBridge.RunProxy(parentPid, e.Args[proxyIdx + 2], e.Args[proxyIdx + 3]);
            return;
        }
        base.OnStartup(e);
        var win = new MainWindow();
        MainWindow = win;
        win.Show();
    }

    public App()
    {
        DispatcherUnhandledException += (_, e) =>
        {
            OmniFlowPaths.AppendCrashLog("DispatcherUnhandledException", e.Exception);
            bool isFatal = IsFatalException(e.Exception) || (++_recoverableUiErrorCount >= 5);
            if (isFatal)
            {
                e.Handled = true;
                if (System.Threading.Interlocked.Exchange(ref _fatalHandlingStarted, 1) == 0)
                {
                    if (!IsDropProxyMode)
                    {
                        try
                        {
                            MessageBox.Show(
                                $"OmniFlow 遇到不可恢复错误，即将安全退出。\n详情已记录至:\n{OmniFlowPaths.CrashLogPath}",
                                "OmniFlow 错误",
                                MessageBoxButton.OK,
                                MessageBoxImage.Error);
                        }
                        catch { }
                    }
                    try { Shutdown(1); } catch { Environment.Exit(1); }
                }
            }
            else
            {
                e.Handled = true;
            }
        };

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex)
                OmniFlowPaths.AppendCrashLog(e.IsTerminating ? "AppDomainFatal" : "AppDomainUnhandled", ex);
        };

        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            OmniFlowPaths.AppendCrashLog("UnobservedTaskException", e.Exception);
            e.SetObserved();
        };
    }

    private static bool IsFatalException(Exception ex) =>
        ex is OutOfMemoryException or StackOverflowException or AccessViolationException or BadImageFormatException;
}
