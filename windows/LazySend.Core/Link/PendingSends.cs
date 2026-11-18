namespace LazySend.Core;

/// <summary>A file sent to a computer that is not finished: enough to carry on after the app was closed.</summary>
public sealed record PendingSend(string HostId, string SendId, string Path, long Size, DateTimeOffset Modified, string Sha256);

public sealed class PendingFile
{
    public List<PendingSend> Sends { get; set; } = [];
}

/// <summary>The unfinished file sends to other computers, in pending.json. Safe to use from any thread.</summary>
public sealed class PendingSends
{
    private readonly string _path;
    private readonly object _gate = new();
    private readonly PendingFile _file;

    public PendingSends(string path)
    {
        _path = path;
        _file = JsonFile.Load<PendingFile>(path);
    }

    public IReadOnlyList<PendingSend> Sends
    {
        get
        {
            lock (_gate) return [.. _file.Sends];
        }
    }

    public void Add(PendingSend send)
    {
        lock (_gate)
        {
            _file.Sends.RemoveAll(s => s.SendId == send.SendId);
            _file.Sends.Add(send);
            Save();
        }
    }

    public void Remove(string sendId)
    {
        lock (_gate)
        {
            if (_file.Sends.RemoveAll(s => s.SendId == sendId) > 0) Save();
        }
    }

    public void RemoveHost(string hostId)
    {
        lock (_gate)
        {
            if (_file.Sends.RemoveAll(s => s.HostId == hostId) > 0) Save();
        }
    }

    // A send that cannot be noted is still sent, it just does not carry on after a restart.
    private void Save()
    {
        try
        {
            JsonFile.Save(_path, _file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
