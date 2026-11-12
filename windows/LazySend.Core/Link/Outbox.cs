namespace LazySend.Core;

/// <summary>Something the computer wants a phone to have. A file stays where it is on the computer and is read when the phone downloads it.</summary>
public sealed class OutboxItem
{
    public string Id { get; set; } = "";
    public string DeviceId { get; set; } = "";
    public string Kind { get; set; } = "";
    public string? Text { get; set; }
    public string? Url { get; set; }
    /// <summary>The path on this computer (files only).</summary>
    public string? Path { get; set; }
    public string? Name { get; set; }
    public long? Size { get; set; }
    public string? Mime { get; set; }
    public DateTimeOffset Queued { get; set; }

    public OutboxEntry ToEntry() => new(Id, Kind, Text, Url, Name, Size, Mime);
}

public sealed class OutboxFile
{
    public List<OutboxItem> Items { get; set; } = [];
}

/// <summary>
/// What waits for each phone to pick it up, kept in outbox.json so it survives a restart. An item
/// stays until the phone acknowledges it. A phone that asks for the outbox with nothing in it waits
/// (<see cref="WaitAsync"/>) and is woken when something is queued. Safe to use from any thread.
/// </summary>
public sealed class Outbox
{
    public const int MaxItemsPerDevice = 1000;

    private readonly string _path;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();
    private readonly OutboxFile _file;
    private readonly Dictionary<string, TaskCompletionSource> _waiting = [];

    public Outbox(string path, Func<DateTimeOffset>? clock = null)
    {
        _path = path;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _file = JsonFile.Load<OutboxFile>(path);
    }

    /// <summary>Raised after an item was queued or removed (on the thread that changed it).</summary>
    public event EventHandler? Changed;

    public OutboxItem QueueText(string deviceId, string text)
    {
        if (text.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(text) > Protocol.MaxTextBytes) throw new ArgumentException("The text is empty or too long.", nameof(text));
        return Add(new OutboxItem { Kind = ItemKind.Text, Text = text }, deviceId);
    }

    public OutboxItem QueueLink(string deviceId, string url)
    {
        if (!ReceivedLinks.IsAcceptable(url)) throw new ArgumentException("Only http and https addresses can be sent.", nameof(url));
        return Add(new OutboxItem { Kind = ItemKind.Link, Url = url }, deviceId);
    }

    /// <summary>Queues the file at <paramref name="path"/>; throws <see cref="FileNotFoundException"/> when there is none.</summary>
    public OutboxItem QueueFile(string deviceId, string path, string? mime = null)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("The file does not exist.", path);
        return Add(new OutboxItem { Kind = ItemKind.File, Path = info.FullName, Name = info.Name, Size = info.Length, Mime = mime }, deviceId);
    }

    public IReadOnlyList<OutboxItem> Pending(string deviceId)
    {
        lock (_gate) return [.. _file.Items.Where(i => i.DeviceId == deviceId)];
    }

    public OutboxItem? Find(string deviceId, string id)
    {
        lock (_gate) return _file.Items.FirstOrDefault(i => i.DeviceId == deviceId && i.Id == id);
    }

    /// <summary>The phone's pending items; when there are none, waits up to <paramref name="wait"/> for one to be queued.</summary>
    public async Task<IReadOnlyList<OutboxItem>> WaitAsync(string deviceId, TimeSpan wait, CancellationToken cancellation)
    {
        TaskCompletionSource signal;
        lock (_gate)
        {
            var items = Pending(deviceId);
            if (items.Count > 0 || wait <= TimeSpan.Zero) return items;
            if (!_waiting.TryGetValue(deviceId, out signal!))
            {
                signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _waiting[deviceId] = signal;
            }
        }
        try
        {
            await signal.Task.WaitAsync(wait, cancellation).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Nothing came; the phone asks again.
        }
        return Pending(deviceId);
    }

    /// <summary>The phone has the item: removes it. False when it was not there.</summary>
    public bool Acknowledge(string deviceId, string id)
    {
        lock (_gate)
        {
            if (_file.Items.RemoveAll(i => i.DeviceId == deviceId && i.Id == id) == 0) return false;
            JsonFile.Save(_path, _file);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Drops everything waiting for the phone (it was removed, or the user cleared the queue).</summary>
    public void Clear(string deviceId)
    {
        lock (_gate)
        {
            if (_file.Items.RemoveAll(i => i.DeviceId == deviceId) == 0) return;
            JsonFile.Save(_path, _file);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private OutboxItem Add(OutboxItem item, string deviceId)
    {
        item.Id = Protocol.NewId();
        item.DeviceId = deviceId;
        item.Queued = _clock();
        TaskCompletionSource? signal;
        lock (_gate)
        {
            if (_file.Items.Count(i => i.DeviceId == deviceId) >= MaxItemsPerDevice) throw new InvalidOperationException("Too many items wait for this phone.");
            _file.Items.Add(item);
            JsonFile.Save(_path, _file);
            if (_waiting.Remove(deviceId, out signal)) signal.TrySetResult();
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return item;
    }
}

/// <summary>What a link has to look like to be kept or sent.</summary>
public static class ReceivedLinks
{
    /// <summary>An absolute http or https address of at most <see cref="Protocol.MaxUrlLength"/> characters. Other schemes are refused because the app opens what arrives.</summary>
    public static bool IsAcceptable(string? url) =>
        url is { Length: > 0 and <= Protocol.MaxUrlLength }
        && Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https";
}
