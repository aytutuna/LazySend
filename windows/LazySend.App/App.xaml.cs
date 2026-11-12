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
    private TrayIcon? _tray;
    private bool _toldAboutTray;

    /// <summary>Set once the user chose Quit; until then closing the window only hides it.</summary>
    public static bool Quitting { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        bool minimized = e.Args.Contains(MinimizedFlag);
        var files = FilesOf(e.Args);
        _instance = new Mutex(true, InstanceMutexName, out bool first);
        if (!first)
        {
            // The running instance takes the files (or comes forward); a second start at sign-in has nothing to hand over.
            bool handed = minimized || InstanceChannel.Send(files) || InstanceChannel.Send(files);
            _instance.Dispose();
            _instance = null;
            if (!handed) MessageBox.Show("Lazy Send is already running, but it did not answer. Quit it from the tray icon or Task Manager and start it again.", "Lazy Send", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);

        try
        {
            _model = new AppModel(SendPaths.Default, new CertificateStore(), Dispatcher);
        }
        catch (CryptographicException error)
        {
            MessageBox.Show($"Lazy Send could not open its security key: {error.Message}", "Lazy Send", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        _model.Start();
        _model.Arrived += OnArrived;
        _model.PairingRequested += (_, name) =>
        {
            if (MainWindow is not { IsVisible: true }) _tray?.Balloon("Pairing request", $"{name} wants to pair. Open Lazy Send to answer.", force: true);
        };
        _channel = new InstanceChannel(Opened);
        var window = new MainWindow(_model);
        MainWindow = window;
        _tray = new TrayIcon(window.ShowAndActivate, Quit);
        if (!minimized || files.Count > 0) window.Show();
        if (files.Count > 0) SendOrShow(files);
    }

    internal static IReadOnlyList<string> FilesOf(IEnumerable<string> args) =>
        [.. args.Where(arg => arg.Length > 0 && !arg.StartsWith("--", StringComparison.Ordinal)).Select(Path.GetFullPath)];

    /// <summary>Files handed over by a second start (Explorer's Send to); an empty list asks for the window.</summary>
    private void Opened(IReadOnlyList<string> paths) => Dispatcher.BeginInvoke(() =>
    {
        if (paths.Count == 0) (MainWindow as MainWindow)?.ShowAndActivate();
        else SendOrShow(paths);
    });

    /// <summary>Sends the files to the selected phone; with no phone to send to, the window opens to say so.</summary>
    private void SendOrShow(IReadOnlyList<string> paths)
    {
        if (_model is null || MainWindow is not MainWindow window) return;
        int sent = _model.SendFiles(paths);
        if (sent == 0) window.ShowAndActivate();
        else if (!window.IsVisible) _tray?.Balloon("Lazy Send", $"{sent} {(sent == 1 ? "file is" : "files are")} waiting for {_model.SelectedPhone?.Name}.", force: true);
    }

    private void OnArrived(object? sender, TimelineItem item)
    {
        if (MainWindow is { IsVisible: true, WindowState: not WindowState.Minimized }) return;
        string text = item.Kind switch
        {
            TimelineKind.File => $"{item.Heading} from {item.DeviceName}",
            TimelineKind.Gallery => item.Heading,
            _ => item.Heading,
        };
        _tray?.Balloon("Lazy Send", text);
    }

    internal void WindowHidden()
    {
        if (_toldAboutTray) return;
        _toldAboutTray = true;
        _tray?.Balloon("Lazy Send is still running", "It stays in the tray so phones can send. Quit it from the tray menu.", force: true);
    }

    private void Quit()
    {
        Quitting = true;
        _tray?.Dispose();
        _tray = null;
        MainWindow?.Close();
        Shutdown();
    }

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
        _tray?.Dispose();
        _channel?.Dispose();
        _model?.Dispose();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
