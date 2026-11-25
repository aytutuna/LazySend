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
        bool existed = File.Exists(path);
        _file = JsonFile.Load<PendingFile>(path);
        // A file that did not parse was moved aside by Load; one that parsed with entries that cannot be sent (no computer,
        // no path) is copied aside and those entries are left out, so start-up never meets them.
        var usable = _file.Sends.Where(s => s is not null && !string.IsNullOrWhiteSpace(s.HostId) && !string.IsNullOrWhiteSpace(s.SendId)
                                            && !string.IsNullOrWhiteSpace(s.Path)).ToList();
        Damaged = (existed && !File.Exists(path)) || usable.Count != _file.Sends.Count;
        if (usable.Count != _file.Sends.Count)
        {
            try
            {
                File.Copy(path, path + ".bad", overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The damaged entries are still left out.
            }
            _file.Sends = usable;
            Save();
        }
    }

    /// <summary>The saved list could not be read or held entries that cannot be sent; it is kept aside as pending.json.bad.</summary>
    public bool Damaged { get; }

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
