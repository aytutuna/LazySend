using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly DispatcherTimer _noticeTimer = new() { Interval = TimeSpan.FromSeconds(8) };
    private PairWindow? _pairWindow;

    public MainWindow(AppModel model)
    {
        _model = model;
        DataContext = model;
        InitializeComponent();
        model.StatusChanged += (_, _) => ShowStatus();
        model.SelectionChanged += (_, _) => ShowSelection();
        model.Notice += (_, text) => ShowNotice(text);
        model.Timeline.CollectionChanged += (_, _) => EmptyText.Visibility = model.Timeline.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        model.Phones.CollectionChanged += (_, _) => NoPhonesText.Visibility = model.Phones.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _noticeTimer.Tick += (_, _) =>
        {
            _noticeTimer.Stop();
            NoticeText.Visibility = Visibility.Collapsed;
        };
        EmptyText.Visibility = model.Timeline.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoPhonesText.Visibility = model.Phones.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowStatus();
        ShowSelection();
    }

    private void ShowStatus()
    {
        if (_model.StartError is { } error)
        {
            StatusText.Text = error;
            return;
        }
        string text = $"Listening for phones on port {_model.Port}.";
        if (_model.FirewallVerdict == FirewallVerdict.Blocked) text += " Windows Firewall blocks Lazy Send; open Pair a phone for details.";
        StatusText.Text = text;
    }

    private void ShowSelection()
    {
        var phone = _model.SelectedPhone;
        TargetText.Text = phone is null ? "Lazy Send" : $"Send to {phone.Name}";
        if (!ReferenceEquals(PhonesList.SelectedItem, phone)) PhonesList.SelectedItem = phone;
    }

    private void ShowNotice(string text)
    {
        NoticeText.Text = text;
        NoticeText.Visibility = Visibility.Visible;
        _noticeTimer.Stop();
        _noticeTimer.Start();
    }

    private void PhonesList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PhonesList.SelectedItem is PhoneRow row) _model.SelectPhone(row);
    }

    private void Pair_Click(object sender, RoutedEventArgs e)
    {
        if (_pairWindow is { IsLoaded: true })
        {
            _pairWindow.Activate();
            return;
        }
        _pairWindow = new PairWindow(_model) { Owner = this };
        _pairWindow.Show();
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => new SettingsWindow(_model) { Owner = this }.ShowDialog();

    private void RemovePhone_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not PhoneRow phone) return;
        var answer = MessageBox.Show(this, $"Remove {phone.Name}? It will need to pair again before it can send anything.", "Lazy Send",
                                     MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.OK) _model.RemovePhone(phone);
    }

    private void Send_Click(object sender, RoutedEventArgs e) => SendComposed();

    private void SendComposed()
    {
        if (!_model.SendText(ComposeBox.Text)) return;
        ComposeBox.Clear();
    }

    private void Compose_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        // Enter sends, Shift+Enter starts a new line.
        if (e.Key != Key.Enter || (Keyboard.Modifiers & ModifierKeys.Shift) != 0) return;
        e.Handled = true;
        SendComposed();
    }

    private void Compose_TextChanged(object sender, TextChangedEventArgs e) =>
        ComposeHint.Visibility = ComposeBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void SendFiles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Send files" };
        if (dialog.ShowDialog(this) == true) _model.SendFiles(dialog.FileNames);
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void Window_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files) _model.SendFiles(files);
    }

    /// <summary>Ctrl+V outside the text box sends what is on the clipboard: files, an image (as a PNG) or text.</summary>
    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.V || (Keyboard.Modifiers & ModifierKeys.Control) == 0 || Keyboard.FocusedElement is TextBoxBase) return;
        e.Handled = true;
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                _model.SendFiles(Clipboard.GetFileDropList().Cast<string>().ToList());
            }
            else if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
            {
                string saved;
                try
                {
                    saved = SaveClipboardImage(image);
                }
                catch (IOException error)
                {
                    ShowNotice($"Could not save the pasted image: {error.Message}");
                    return;
                }
                _model.SendFiles([saved]);
            }
            else if (Clipboard.ContainsText())
            {
                _model.SendText(Clipboard.GetText());
            }
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            ShowNotice("Another program is using the clipboard. Try again.");
        }
    }

    private string SaveClipboardImage(BitmapSource image)
    {
        string folder = Path.Combine(_model.Paths.State, "clipboard");
        Directory.CreateDirectory(folder);
        string path = ClipboardFiles.NewImagePath(folder, DateTime.Now);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = File.Create(path);
        encoder.Save(stream);
        return path;
    }

    private static TimelineItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as TimelineItem;

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender)?.Text is not { } text) return;
        try
        {
            Clipboard.SetText(text);
            ShowNotice("Copied.");
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            ShowNotice("Another program is using the clipboard. Try again.");
        }
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } item) return;
        string? target = item.Kind == TimelineKind.Link ? item.Text : item.Path;
        if (target is null) return;
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            ShowNotice($"Could not open it: {error.Message}");
        }
    }

    private void ShowInFolder_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender)?.Path is not { } path) return;
        if (File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        else ShowNotice("The file is not there any more.");
    }

    private void CancelItem_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) _model.Cancel(item);
    }

    /// <summary>Closing the window keeps the app in the tray, so phones can still send.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!App.Quitting)
        {
            e.Cancel = true;
            Hide();
            (Application.Current as App)?.WindowHidden();
        }
        base.OnClosing(e);
    }

    public void ShowAndActivate()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }
}
