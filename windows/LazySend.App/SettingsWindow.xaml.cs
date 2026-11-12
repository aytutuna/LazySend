using System.IO;
using System.Windows;
using LazySend.App.Services;

namespace LazySend.App;

public partial class SettingsWindow : Window
{
    private readonly AppModel _model;
    private bool _loading = true;

    public SettingsWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        FolderBox.Text = model.Service.Settings.ReceiveRoot;
        CopyBox.IsChecked = model.Settings.CopyReceivedText;
        StartBox.IsChecked = ShellIntegration.StartWithWindows;
        if (ShellIntegration.StartWithWindowsLocked is { } locked)
        {
            StartBox.IsEnabled = false;
            FooterStatus.Text = locked;
        }
        SendToBox.IsChecked = ShellIntegration.SendToShortcut;
        _loading = false;
    }

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Where should received files go?", InitialDirectory = FolderBox.Text };
        if (dialog.ShowDialog(this) == true) SetFolder(dialog.FolderName);
    }

    private void DefaultFolder_Click(object sender, RoutedEventArgs e) => SetFolder(_model.Paths.DefaultReceiveRoot);

    private void SetFolder(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            _model.Service.Settings.ReceiveRoot = folder;
            FolderBox.Text = folder;
            FooterStatus.Text = "";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            FooterStatus.Text = $"That folder cannot be used: {error.Message}";
        }
    }

    private void Copy_Changed(object sender, RoutedEventArgs e)
    {
        if (!_loading) _model.Settings.CopyReceivedText = CopyBox.IsChecked == true;
    }

    private void Start_Changed(object sender, RoutedEventArgs e) => Apply(StartBox, v => ShellIntegration.StartWithWindows = v);

    private void SendTo_Changed(object sender, RoutedEventArgs e) => Apply(SendToBox, v => ShellIntegration.SendToShortcut = v);

    private void Apply(System.Windows.Controls.CheckBox box, Action<bool> set)
    {
        if (_loading) return;
        try
        {
            set(box.IsChecked == true);
            FooterStatus.Text = "";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException
                                          or System.Runtime.InteropServices.COMException or System.Security.SecurityException)
        {
            _loading = true;
            box.IsChecked = !box.IsChecked;
            _loading = false;
            FooterStatus.Text = $"Windows would not allow that: {error.Message}";
        }
    }
}
