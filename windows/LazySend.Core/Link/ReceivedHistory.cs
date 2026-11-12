using System.Text;

namespace LazySend.Core;

public sealed record ReceivedItem(string Id, string DeviceId, string DeviceName, string Kind, string? Text, string? Url, DateTimeOffset Received);

public sealed class HistoryFile
{
    public List<ReceivedItem> Items { get; set; } = [];
}

/// <summary>
/// The texts and links received, newest first, kept in history.json. Old entries go when there are
/// more than <see cref="MaxItems"/> or their text adds up to more than <see cref="MaxTextBytes"/>.
/// Safe to use from any thread.
/// </summary>
public sealed class ReceivedHistory
{
    public const int MaxItems = 500;
    public const long MaxTextBytes = 16 * 1024 * 1024;

    private readonly string _path;
    private readonly object _gate = new();
    private readonly HistoryFile _file;

    public ReceivedHistory(string path)
    {
        _path = path;
        _file = JsonFile.Load<HistoryFile>(path);
    }

    public event EventHandler? Changed;

    public IReadOnlyList<ReceivedItem> Items
    {
        get
        {
            lock (_gate) return [.. _file.Items];
        }
    }

    public ReceivedItem Add(PairedDevice device, string kind, string? text, string? url, DateTimeOffset now)
    {
        var item = new ReceivedItem(Protocol.NewId(), device.Id, device.Name, kind, text, url, now);
        lock (_gate)
        {
            _file.Items.Insert(0, item);
            long bytes = 0;
            int keep = 0;
            foreach (var entry in _file.Items)
            {
                bytes += Encoding.UTF8.GetByteCount(entry.Text ?? "") + Encoding.UTF8.GetByteCount(entry.Url ?? "");
                if (keep >= MaxItems || (keep > 0 && bytes > MaxTextBytes)) break;
                keep++;
            }
            _file.Items.RemoveRange(keep, _file.Items.Count - keep);
            JsonFile.Save(_path, _file);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return item;
    }

    public bool Remove(string id)
    {
        lock (_gate)
        {
            if (_file.Items.RemoveAll(i => i.Id == id) == 0) return false;
            JsonFile.Save(_path, _file);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void Clear()
    {
        lock (_gate)
        {
            _file.Items.Clear();
            JsonFile.Save(_path, _file);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
