using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;

namespace LazySend.App;

public enum TimelineKind
{
    Text,
    Link,
    File,
    Gallery,
}

public sealed class TimelineItem : INotifyPropertyChanged
{
    private string _heading = "";
    private string _detail = "";
    private bool _canCancel;

    public TimelineItem(TimelineKind kind, bool sent, string deviceId, string deviceName, DateTimeOffset time)
    {
        Kind = kind;
        Sent = sent;
        DeviceId = deviceId;
        DeviceName = deviceName;
        Time = time;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public TimelineKind Kind { get; }
    public bool Sent { get; }
    public string DeviceId { get; }
    public string DeviceName { get; }
    public DateTimeOffset Time { get; }

    public string? Text { get; init; }

    public string? Path { get; set; }

    public string? OutboxId { get; init; }

    private ImageSource? _thumbnail;

    public ImageSource? Thumbnail
    {
        get => _thumbnail;
        set
        {
            _thumbnail = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasThumbnail)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ShowGlyph)));
        }
    }

    /// <summary>Set before a waiting item is withdrawn, so its removal reads as cancelled and not delivered.</summary>
    public bool Cancelling { get; set; }

    public long Count { get; set; }
    public DateTimeOffset LastArrival { get; set; }

    public bool Active { get; set; }

    public string Heading
    {
        get => _heading;
        set => Set(ref _heading, value);
    }

    public string Detail
    {
        get => _detail;
        set => Set(ref _detail, value);
    }

    public bool CanCancel
    {
        get => _canCancel;
        set => Set(ref _canCancel, value);
    }

    public string? Body => Kind is TimelineKind.Text or TimelineKind.Link
        ? Text is { Length: > 1200 } whole ? whole[..1200] + "…" : Text
        : null;

    public bool HasBody => Body is not null;
    public bool CanCopy => Kind is TimelineKind.Text or TimelineKind.Link;
    public bool CanOpen => Kind is TimelineKind.Link or TimelineKind.File or TimelineKind.Gallery;
    public bool CanShowFolder => Kind == TimelineKind.File && Path is not null;
    public bool HasThumbnail => Thumbnail is not null;
    public bool ShowGlyph => Thumbnail is null;

    public string Glyph => Kind switch
    {
        TimelineKind.Text => "",
        TimelineKind.Link => "",
        TimelineKind.Gallery => "",
        _ => "",
    };

    public string OpenLabel => Kind == TimelineKind.Gallery ? "Open folder" : "Open";

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}
