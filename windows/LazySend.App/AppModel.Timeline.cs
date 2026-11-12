using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

public sealed class PhoneRow(string id, string name, string platform) : INotifyPropertyChanged
{
    private string _lastSeen = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; } = id;
    public string Name { get; set; } = name;
    public string Platform { get; } = platform;

    public string LastSeen
    {
        get => _lastSeen;
        set
        {
            if (_lastSeen == value) return;
            _lastSeen = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LastSeen)));
        }
    }
}

public sealed partial class AppModel
{
    private static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic"];
    private static readonly TimeSpan GalleryIdle = TimeSpan.FromSeconds(8);
    private const int MaxRows = 500;
    private const long MaxThumbnailPixels = 50_000_000;
    private static readonly SemaphoreSlim ThumbnailSlots = new(2);

    private readonly Dictionary<string, TimelineItem> _galleries = [];
    private DispatcherTimer? _tick;
    private string? _selectedId;
    private int _refreshQueued;

    public ObservableCollection<TimelineItem> Timeline { get; } = [];

    public ObservableCollection<PhoneRow> Phones { get; } = [];

    public PhoneRow? SelectedPhone => Phones.FirstOrDefault(p => p.Id == _selectedId);

    public event EventHandler<TimelineItem>? Arrived;

    public event EventHandler? SelectionChanged;

    public event EventHandler<string>? Notice;

    private void StartTimeline()
    {
        Service.Router.TextReceived += (_, item) => _ui.BeginInvoke(() => AddReceivedText(item));
        Service.Inbox.FileReceived += (_, file) => _ui.BeginInvoke(() => AddReceivedFile(file));
        Service.Outbox.Changed += (_, _) =>
        {
            if (Interlocked.Exchange(ref _refreshQueued, 1) != 0) return;
            _ui.BeginInvoke(() =>
            {
                Volatile.Write(ref _refreshQueued, 0);
                RefreshSent();
            });
        };
        Service.Devices.Changed += (_, _) => _ui.BeginInvoke(RefreshPhones);
        RefreshPhones();
        foreach (var item in Service.History.Items.Reverse()) AddReceivedText(item, arrived: false);
        foreach (var phone in Service.Devices.Devices)
        {
            foreach (var waiting in Service.Outbox.Pending(phone.Id)) AddWaiting(waiting, phone.Name);
        }
        ClipboardFiles.Cleanup(System.IO.Path.Combine(Paths.State, "clipboard"),
                               Service.Devices.Devices.SelectMany(d => Service.Outbox.Pending(d.Id)).Select(i => i.Path).OfType<string>());
        _tick = new DispatcherTimer(DispatcherPriority.Background, _ui) { Interval = TimeSpan.FromSeconds(2) };
        _tick.Tick += (_, _) =>
        {
            FinishGalleries();
            UpdateLastSeen();
        };
        _tick.Start();
    }

    public void SelectPhone(PhoneRow? phone)
    {
        if (phone?.Id == _selectedId) return;
        _selectedId = phone?.Id;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void RefreshPhones()
    {
        var devices = Service.Devices.Devices;
        for (int i = Phones.Count - 1; i >= 0; i--)
        {
            if (devices.All(d => d.Id != Phones[i].Id)) Phones.RemoveAt(i);
        }
        foreach (var device in devices)
        {
            if (Phones.FirstOrDefault(p => p.Id == device.Id) is { } row) row.Name = device.Name;
            else Phones.Add(new PhoneRow(device.Id, device.Name, device.Platform));
        }
        UpdateLastSeen();
        if (SelectedPhone is null) SelectPhone(Phones.FirstOrDefault());
        else SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateLastSeen()
    {
        var devices = Service.Devices.Devices;
        foreach (var row in Phones)
        {
            if (devices.FirstOrDefault(d => d.Id == row.Id)?.LastSeen is not { } seen) continue;
            var ago = DateTimeOffset.UtcNow - seen;
            row.LastSeen = ago < TimeSpan.FromMinutes(2) ? "Connected just now"
                : ago < TimeSpan.FromHours(1) ? $"Seen {(int)ago.TotalMinutes} minutes ago"
                : $"Seen {seen.ToLocalTime():g}";
        }
    }

    public void RemovePhone(PhoneRow phone) => Service.Devices.Remove(phone.Id);

    private void AddReceivedText(ReceivedItem item, bool arrived = true)
    {
        bool link = item.Kind == ItemKind.Link;
        var row = new TimelineItem(link ? TimelineKind.Link : TimelineKind.Text, false, item.DeviceId, item.DeviceName, item.Received)
        {
            Text = link ? item.Url : item.Text,
        };
        row.Heading = link ? $"Link from {item.DeviceName}" : $"Text from {item.DeviceName}";
        row.Detail = Stamp(item.Received);
        Push(row);
        if (arrived && !link && Settings.CopyReceivedText) CopyToClipboard(item.Text);
        if (arrived) Arrived?.Invoke(this, row);
    }

    private void AddReceivedFile(ReceivedFile file)
    {
        var now = DateTimeOffset.UtcNow;
        if (file.SourceId is not null)
        {
            AddGalleryFile(file, now);
            return;
        }
        var row = new TimelineItem(TimelineKind.File, false, file.DeviceId, file.DeviceName, now)
        {
            Path = file.Path,
        };
        row.Heading = System.IO.Path.GetFileName(file.Path);
        row.Detail = $"{LinkDetector.FormatSize(file.Size)}, from {file.DeviceName}, {Stamp(now)}";
        Push(row);
        LoadThumbnail(row, file.Path, file.Size);
        Arrived?.Invoke(this, row);
    }

    private void AddGalleryFile(ReceivedFile file, DateTimeOffset now)
    {
        if (!_galleries.TryGetValue(file.DeviceId, out var row) || !row.Active)
        {
            row = new TimelineItem(TimelineKind.Gallery, false, file.DeviceId, file.DeviceName, now)
            {
                Path = System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(file.Path)),
                Active = true,
            };
            _galleries[file.DeviceId] = row;
            Push(row);
            Arrived?.Invoke(this, row);
        }
        row.Count++;
        row.LastArrival = now;
        DescribeGallery(row);
    }

    private static void DescribeGallery(TimelineItem row)
    {
        row.Heading = row.Active
            ? $"Receiving photos from {row.DeviceName}: {row.Count:N0} so far"
            : $"Received {row.Count:N0} photos and videos from {row.DeviceName}";
        row.Detail = Stamp(row.Time);
    }

    /// <summary>A gallery row is done once nothing has arrived for a while and the phone has nothing more in progress.</summary>
    private void FinishGalleries()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var row in _galleries.Values.Where(r => r.Active && now - r.LastArrival > GalleryIdle))
        {
            if (Service.Inbox.InProgress.Any(f => f.DeviceId == row.DeviceId && f.SourceId is not null)) continue;
            row.Active = false;
            DescribeGallery(row);
        }
    }

    public bool SendText(string text)
    {
        if (!HasTarget(out var phone)) return false;
        string trimmed = text.Trim();
        if (trimmed.Length == 0) return false;
        try
        {
            if (LinkDetector.IsLink(trimmed)) AddSent(Service.Outbox.QueueLink(phone.Id, trimmed), phone);
            else AddSent(Service.Outbox.QueueText(phone.Id, text.TrimEnd()), phone);
            return true;
        }
        catch (ArgumentException)
        {
            Notice?.Invoke(this, "That text is too long to send (the limit is 1 MiB).");
        }
        catch (InvalidOperationException)
        {
            Notice?.Invoke(this, $"Too many items are waiting for {phone.Name}. Wait until it picks some up.");
        }
        return false;
    }

    public int SendFiles(IEnumerable<string> paths)
    {
        if (!HasTarget(out var phone)) return 0;
        var files = new List<string>();
        string? problem = null;
        foreach (string path in paths)
        {
            if (Directory.Exists(path)) problem = "Folders cannot be sent yet. Send the files in them, or zip the folder first.";
            else if (!File.Exists(path)) problem = $"{System.IO.Path.GetFileName(path)} is not there any more.";
            else files.Add(path);
        }
        // One save for the whole drop, however many files it holds.
        var queued = files.Count == 0 ? [] : Service.Outbox.QueueFiles(phone.Id, files);
        foreach (var item in queued) AddSent(item, phone);
        if (queued.Count < files.Count) problem = $"Too many items are waiting for {phone.Name}. Wait until it picks some up.";
        if (problem is not null) Notice?.Invoke(this, problem);
        return queued.Count;
    }

    private bool HasTarget(out PhoneRow phone)
    {
        phone = SelectedPhone!;
        if (phone is not null) return true;
        Notice?.Invoke(this, "Pair a phone first.");
        return false;
    }

    private void AddSent(OutboxItem item, PhoneRow phone)
    {
        var row = new TimelineItem(item.Kind switch
        {
            ItemKind.Link => TimelineKind.Link,
            ItemKind.File => TimelineKind.File,
            _ => TimelineKind.Text,
        }, true, phone.Id, phone.Name, item.Queued)
        {
            Text = item.Kind == ItemKind.Link ? item.Url : item.Text,
            Path = item.Path,
            OutboxId = item.Id,
        };
        row.Heading = item.Kind switch
        {
            ItemKind.File => item.Name ?? "File",
            ItemKind.Link => $"Link to {phone.Name}",
            _ => $"Text to {phone.Name}",
        };
        row.CanCancel = true;
        DescribeSent(row, "Waiting for " + phone.Name);
        Push(row);
        if (item.Path is { } path) LoadThumbnail(row, path, item.Size ?? 0);
    }

    private void AddWaiting(OutboxItem item, string deviceName) =>
        AddSent(item, Phones.FirstOrDefault(p => p.Id == item.DeviceId) ?? new PhoneRow(item.DeviceId, deviceName, ""));

    private static void DescribeSent(TimelineItem row, string status)
    {
        string size = row.Kind == TimelineKind.File && row.Path is { } path && File.Exists(path) ? LinkDetector.FormatSize(new FileInfo(path).Length) + ", " : "";
        row.Detail = $"{size}{status}, {Stamp(row.Time)}";
    }

    /// <summary>Waiting items that left the outbox were picked up by the phone, or withdrawn here.</summary>
    private void RefreshSent()
    {
        var paired = Service.Devices.Devices.Select(d => d.Id).ToHashSet();
        foreach (var row in Timeline.Where(r => r.Sent && r.CanCancel).ToList())
        {
            if (row.OutboxId is null || Service.Outbox.Find(row.DeviceId, row.OutboxId) is not null) continue;
            row.CanCancel = false;
            DescribeSent(row, SentStatus(row, paired.Contains(row.DeviceId)));
        }
    }

    /// <summary>What it means that an item left the outbox: withdrawn here, or dropped with its phone, or picked up.</summary>
    internal static string SentStatus(TimelineItem row, bool phoneStillPaired) =>
        row.Cancelling || !phoneStillPaired ? "Cancelled" : "Delivered";

    public void Cancel(TimelineItem row)
    {
        if (!row.CanCancel || row.OutboxId is null) return;
        row.Cancelling = true;
        if (!Service.Outbox.Acknowledge(row.DeviceId, row.OutboxId)) RefreshSent();
    }

    private static void CopyToClipboard(string? text)
    {
        if (string.IsNullOrEmpty(text)) return;
        try
        {
            System.Windows.Clipboard.SetText(text);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another program holds the clipboard; the text is still in the timeline.
        }
    }

    private static string Stamp(DateTimeOffset time) => time.ToLocalTime().ToString("g");

    /// <summary>Adds a row at the top; past <see cref="MaxRows"/> the oldest rows go, except those still waiting for a phone.</summary>
    private void Push(TimelineItem row)
    {
        Timeline.Insert(0, row);
        for (int i = Timeline.Count - 1; i >= 0 && Timeline.Count > MaxRows; i--)
        {
            if (!Timeline[i].CanCancel) Timeline.RemoveAt(i);
        }
    }

    /// <summary>Decodes the picture on the pool, two at a time, and puts it on the row when ready.</summary>
    private void LoadThumbnail(TimelineItem row, string path, long size)
    {
        if (size > 64L * 1024 * 1024 || !ImageExtensions.Contains(System.IO.Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) return;
        _ = Task.Run(async () =>
        {
            await ThumbnailSlots.WaitAsync().ConfigureAwait(false);
            try
            {
                if (DecodeThumbnail(path) is { } image) _ = _ui.BeginInvoke(() => row.Thumbnail = image);
            }
            finally
            {
                ThumbnailSlots.Release();
            }
        });
    }

    /// <summary>A frozen 112-pixel-wide copy of the picture; null for what cannot be read or is over about 50 megapixels.</summary>
    internal static ImageSource? DecodeThumbnail(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None).Frames[0];
            if ((long)frame.PixelWidth * frame.PixelHeight > MaxThumbnailPixels) return null;
            stream.Position = 0;
            var image = new BitmapImage();
            image.BeginInit();
            image.StreamSource = stream;
            image.DecodePixelWidth = 112;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception e) when (e is NotSupportedException or IOException or InvalidOperationException or UnauthorizedAccessException
                                      or System.Runtime.InteropServices.COMException or FileFormatException)
        {
            return null;
        }
    }
}
