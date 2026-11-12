using System.IO;
using LazySend.Core;
using Microsoft.Win32;
using Windows.ApplicationModel;

namespace LazySend.App.Services;

public sealed class AppSettingsFile
{
    public bool CopyReceivedText { get; set; }
}

public sealed class AppSettings(SendPaths paths)
{
    private readonly string _path = Path.Combine(paths.Settings, "app.json");
    private readonly AppSettingsFile _file = JsonFile.Load<AppSettingsFile>(Path.Combine(paths.Settings, "app.json"));

    public bool CopyReceivedText
    {
        get => _file.CopyReceivedText;
        set
        {
            _file.CopyReceivedText = value;
            JsonFile.Save(_path, _file);
        }
    }
}

public static class ShellIntegration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "Lazy Send";
    private const string StartupTaskId = "LazySendStartup";
    private const string Alias = "LazySend.exe";

    public static string SendToPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Lazy Send.lnk");

    /// <summary>What the Send to shortcut starts: the package's execution alias, since the exe inside WindowsApps cannot be launched by path.</summary>
    internal static string SendToTarget =>
        Packaging.IsPackaged
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", Alias)
            : Environment.ProcessPath!;

    public static bool StartWithWindows
    {
        get
        {
            if (Packaging.IsPackaged) return StartupState() is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string;
        }
        set
        {
            if (Packaging.IsPackaged)
            {
                SetStartupTask(value);
                return;
            }
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunValue, $"\"{Environment.ProcessPath}\" {App.MinimizedFlag}");
            else key.DeleteValue(RunValue, throwOnMissingValue: false);
        }
    }

    /// <summary>Why the app cannot change the start-with-Windows setting itself, or null when it can.</summary>
    public static string? StartWithWindowsLocked => !Packaging.IsPackaged ? null : StartupState() switch
    {
        StartupTaskState.DisabledByUser => "Start with Windows is turned off in Windows. Turn it on under Settings, Apps, Startup.",
        StartupTaskState.DisabledByPolicy or StartupTaskState.EnabledByPolicy => "Your organization controls whether Lazy Send starts with Windows.",
        _ => null,
    };

    private static StartupTaskState StartupState() => StartupTask.GetAsync(StartupTaskId).AsTask().GetAwaiter().GetResult().State;

    private static void SetStartupTask(bool enable)
    {
        var task = StartupTask.GetAsync(StartupTaskId).AsTask().GetAwaiter().GetResult();
        if (!enable)
        {
            task.Disable();
            return;
        }
        var state = task.RequestEnableAsync().AsTask().GetAwaiter().GetResult();
        if (state is not (StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy))
            throw new InvalidOperationException("Start with Windows is turned off in Windows. Turn it on under Settings, Apps, Startup.");
    }

    public static bool SendToShortcut
    {
        get => File.Exists(SendToPath);
        set
        {
            if (!value)
            {
                File.Delete(SendToPath);
                return;
            }
            var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows has no shortcut service.");
            dynamic shell = Activator.CreateInstance(type)!;
            try
            {
                dynamic link = shell.CreateShortcut(SendToPath);
                link.TargetPath = SendToTarget;
                link.Description = "Send to a phone with Lazy Send";
                link.Save();
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.ReleaseComObject(shell);
            }
        }
    }
}
