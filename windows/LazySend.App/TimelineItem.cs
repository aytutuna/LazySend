using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;

namespace LazySend.App;

public enum TimelineKind
{
    Text,
    Link,
    File,
    /// <summary>The photos and videos of a gallery sync, as one row.</summary>
    Gallery,
}

/// <summary>One row of the timeline: something that arrived from a phone or was sent to one.</summary>
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

    /// <summary>The whole text, or the link's address.</summary>
    public string? Text { get; init; }

    /// <summary>The file's path on this computer, or the folder of a gallery.</summary>
    public string? Path { get; set; }

    /// <summary>The outbox item of something sent, to follow its delivery.</summary>
    public string? OutboxId { get; init; }

    private ImageSource? _thumbnail;

    /// <summary>Set when the picture has been decoded, a moment after the row appears.</summary>
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

    /// <summary>A gallery row whose sync is still going.</summary>
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

    /// <summary>What a row shows under its heading: the text, shortened, or the link.</summary>
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
