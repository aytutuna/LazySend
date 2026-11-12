using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

public sealed class UsbPhoneRow(UsbPhoneInfo info) : INotifyPropertyChanged
{
    private bool _busy;

    public event PropertyChangedEventHandler? PropertyChanged;

    public UsbPhoneInfo Info { get; set; } = info;
    public string Id => Info.Id;
    public string Name => Info.Name;

    public string Status => Info.State switch
    {
        UsbState.LockedApple => "Unlock your iPhone and tap Trust",
        UsbState.NoFileAccess => "On the phone, tap the USB notification and choose File transfer",
        _ => Busy ? "Importing" : "Ready to import",
    };

    public bool CanImport => Info.State == UsbState.Ready && !Busy;

    public bool Busy
    {
        get => _busy;
        set
        {
            _busy = value;
            Refresh();
        }
    }

    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}

public sealed partial class AppModel
{
    private static readonly TimeSpan UsbPoll = TimeSpan.FromSeconds(3);

    private readonly CancellationTokenSource _usbStop = new();
    private PhoneImporter? _importer;
    private int _imports;

    public ObservableCollection<UsbPhoneRow> UsbPhones { get; } = [];

    /// <summary>An Apple phone is on a USB port but Windows does not list it as a portable device.</summary>
    public bool AppleDriverMissing { get; private set; }

    public event EventHandler? UsbChanged;

    private void StartUsb()
    {
        _importer = new PhoneImporter(Service.Gallery, ReceiveRoot);
        _ = Task.Run(WatchUsb);
    }

    private async Task WatchUsb()
    {
        using var timer = new PeriodicTimer(UsbPoll);
        List<UsbPhoneInfo>? last = null;
        bool lastMissing = false;
        try
        {
            do
            {
                // The phones are left alone while one is being read.
                if (Volatile.Read(ref _imports) > 0) continue;
                List<UsbPhoneInfo> phones;
                bool missing;
                try
                {
                    phones = ScanUsb();
                    missing = !phones.Any(p => p.Apple) && UsbDevices.AppleMobileDevicePresent();
                }
                catch (Exception)
                {
                    phones = [];
                    missing = false;
                }
                if (last is not null && phones.SequenceEqual(last) && missing == lastMissing) continue;
                (last, lastMissing) = (phones, missing);
                _ = _ui.BeginInvoke(() => ApplyUsb(phones, missing));
            }
            while (await timer.WaitForNextTickAsync(_usbStop.Token));
        }
        catch (OperationCanceledException)
        {
            // The app is closing.
        }
    }

    private string ReceiveRoot()
    {
#if DEBUG
        if (Environment.GetEnvironmentVariable("LAZYSEND_USB_ROOT") is { Length: > 0 } root) return root;
#endif
        return Service.Settings.ReceiveRoot;
    }

    private static List<UsbPhoneInfo> ScanUsb()
    {
        var phones = WpdDevices.Scan();
#if DEBUG
        if (Environment.GetEnvironmentVariable("LAZYSEND_FAKE_USB") == "1") phones.Add(FakeUsbPhone.Info);
#endif
        return phones;
    }

    private static IPhoneSource OpenUsbPhone(UsbPhoneInfo info)
    {
#if DEBUG
        if (info.Id == FakeUsbPhone.Info.Id) return new FakeUsbPhone();
#endif
        return new WpdPhone(info);
    }

    private void ApplyUsb(List<UsbPhoneInfo> phones, bool appleMissing)
    {
        for (int i = UsbPhones.Count - 1; i >= 0; i--)
        {
            if (phones.All(p => p.Id != UsbPhones[i].Id)) UsbPhones.RemoveAt(i);
        }
        foreach (var info in phones)
        {
            if (UsbPhones.FirstOrDefault(r => r.Id == info.Id) is { } row)
            {
                row.Info = info;
                row.Refresh();
            }
            else
            {
                UsbPhones.Add(new UsbPhoneRow(info));
            }
        }
        AppleDriverMissing = appleMissing;
        UsbChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ImportFromUsb(UsbPhoneRow phone)
    {
        if (!phone.CanImport || _importer is not { } importer) return;
        var info = phone.Info;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(_usbStop.Token);
        var row = new TimelineItem(TimelineKind.Gallery, false, info.Id, info.Name, DateTimeOffset.UtcNow)
        {
            Heading = $"Importing from {info.Name}",
            Detail = "Looking for photos and videos",
            ImportStop = stop,
            Importing = true,
        };
        phone.Busy = true;
        Interlocked.Increment(ref _imports);
        Push(row);
        var progress = new Progress<ImportProgress>(p =>
        {
            if (!row.Importing) return;
            row.Heading = $"Importing from {info.Name}: {p.Done:N0} of {p.Total:N0}, {LinkDetector.FormatSize(p.Bytes)} of {LinkDetector.FormatSize(p.TotalBytes)}";
            row.Detail = Stamp(row.Time);
        });
        _ = Task.Run(() =>
        {
            try
            {
                using var source = OpenUsbPhone(info);
                return importer.Run(source, progress, stop.Token);
            }
            catch (PhoneGoneException e)
            {
                return new ImportResult(ImportOutcome.Disconnected, 0, 0, 0, 0, "", e.Message);
            }
            catch (Exception e)
            {
                return new ImportResult(ImportOutcome.Failed, 0, 0, 0, 0, "", e.Message);
            }
        }).ContinueWith(done => _ui.BeginInvoke(() =>
        {
            Interlocked.Decrement(ref _imports);
            stop.Dispose();
            row.ImportStop = null;
            phone.Busy = false;
            FinishImport(row, info.Name, done.Result);
            Arrived?.Invoke(this, row);
        }));
    }

    public void StopImport(TimelineItem row)
    {
        if (!row.Importing) return;
        row.Heading = $"Stopping the import from {row.DeviceName}";
        try
        {
            row.ImportStop?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // It had just finished.
        }
    }

    private static void FinishImport(TimelineItem row, string phone, ImportResult result)
    {
        if (Directory.Exists(result.Folder)) row.Path = result.Folder;
        row.Importing = false;
        row.Heading = result.Outcome switch
        {
            ImportOutcome.Finished when result.Imported == 0 => $"No new photos or videos on {phone}",
            ImportOutcome.Finished => $"Imported {result.Imported:N0} new photos and videos from {phone}",
            ImportOutcome.Stopped => $"Stopped importing from {phone}: {result.Imported:N0} imported",
            ImportOutcome.Disconnected => $"Lost {phone} after {result.Imported:N0} photos and videos",
            _ => $"Could not finish importing from {phone}",
        };
        var parts = new List<string>();
        if (result.Imported > 0) parts.Add(LinkDetector.FormatSize(result.Bytes));
        if (result.Skipped > 0) parts.Add($"{result.Skipped:N0} already on this PC");
        if (result.Unreadable > 0) parts.Add($"{result.Unreadable:N0} could not be read");
        if (result.Outcome == ImportOutcome.Disconnected) parts.Add("Plug it in, unlock it and import again to continue where it stopped");
        else if (result.Outcome == ImportOutcome.Failed && result.Message is not null) parts.Add(result.Message);
        parts.Add(Stamp(row.Time));
        row.Detail = string.Join(", ", parts);
    }
}
