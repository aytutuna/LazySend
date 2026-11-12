using System.IO;
using LazySend.Core;
using Microsoft.Win32;

namespace LazySend.App.Services;

public sealed class AppSettingsFile
{
    public bool CopyReceivedText { get; set; }
}

/// <summary>The choices the Settings window makes besides the receive folder, which <see cref="SendSettings"/> keeps.</summary>
public sealed class AppSettings(SendPaths paths)
{
    private readonly string _path = Path.Combine(paths.Settings, "app.json");
    private readonly AppSettingsFile _file = JsonFile.Load<AppSettingsFile>(Path.Combine(paths.Settings, "app.json"));

    /// <summary>Text that arrives is also put on the clipboard.</summary>
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

/// <summary>What the app sets up in Windows: starting at sign-in, and a Send to entry in Explorer.</summary>
public static class ShellIntegration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "Lazy Send";

    /// <summary>The Explorer Send to shortcut (shell:sendto).</summary>
    public static string SendToPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Lazy Send.lnk");

    public static bool StartWithWindows
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunValue, $"\"{Environment.ProcessPath}\" {App.MinimizedFlag}");
            else key.DeleteValue(RunValue, throwOnMissingValue: false);
        }
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
                link.TargetPath = Environment.ProcessPath;
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
