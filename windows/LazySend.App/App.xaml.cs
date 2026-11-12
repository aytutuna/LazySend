using System.IO;
using System.Security.Cryptography;
using System.Windows;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

public partial class App : Application
{
    /// <summary>One instance per user session.</summary>
    private const string InstanceMutexName = @"Local\LazySend.App";
    internal const string MinimizedFlag = "--minimized";

    private Mutex? _instance;
    private InstanceChannel? _channel;
    private AppModel? _model;

    protected override void OnStartup(StartupEventArgs e)
    {
        bool minimized = e.Args.Contains(MinimizedFlag);
        var files = FilesOf(e.Args);
        _instance = new Mutex(true, InstanceMutexName, out bool first);
        if (!first)
        {
            // The running instance takes the files (or just comes forward); nothing more to do here, unless nobody answers.
            bool handed = InstanceChannel.Send(files);
            _instance.Dispose();
            _instance = null;
            if (handed)
            {
                Shutdown();
                return;
            }
        }
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);

        try
        {
            _model = new AppModel(SendPaths.Default, new CertificateStore().Current(), Dispatcher);
        }
        catch (CryptographicException error)
        {
            MessageBox.Show($"Lazy Send could not open its security key: {error.Message}", "Lazy Send", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        _model.Start();
        if (first) _channel = new InstanceChannel(Opened);
        var window = new MainWindow(_model);
        MainWindow = window;
        if (!minimized) window.Show();
    }

    /// <summary>The files a command line names: every argument but the flags is a path.</summary>
    internal static IReadOnlyList<string> FilesOf(IEnumerable<string> args) =>
        [.. args.Where(arg => arg.Length > 0 && !arg.StartsWith("--", StringComparison.Ordinal)).Select(Path.GetFullPath)];

    /// <summary>Files handed over by a second start; an empty list asks for the window.</summary>
    private void Opened(IReadOnlyList<string> paths) => Dispatcher.BeginInvoke(() =>
    {
        if (MainWindow is MainWindow window) window.ShowAndActivate();
    });

    private void OnUnhandled(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            string folder = SendPaths.Default.State;
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "errors.txt"), $"{DateTime.Now:g}\n{e.Exception}\n\n");
        }
        catch (IOException write)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not write the error log: {write.Message}");
        }
        if (e.Exception is OutOfMemoryException or AccessViolationException or InsufficientExecutionStackException) return;
        e.Handled = true;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _channel?.Dispose();
        _model?.Dispose();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
