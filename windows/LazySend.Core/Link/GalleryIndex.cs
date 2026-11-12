namespace LazySend.Core;

/// <summary>
/// The source ids (a phone's own asset ids) already received from each phone, so a gallery sync
/// sends only what is new. One text file per phone, an id on each line, appended to as files arrive
/// and read whole once per run; tens of thousands of ids stay in a hash set. Safe to use from any thread.
/// </summary>
public sealed class GalleryIndex(string directory)
{
    private readonly object _gate = new();
    private readonly Dictionary<string, HashSet<string>> _byDevice = [];

    /// <summary>Whether <paramref name="id"/> can be kept: 1 to <see cref="Protocol.MaxSourceIdLength"/> characters, none of them a control character.</summary>
    public static bool IsValidSourceId(string? id) =>
        !string.IsNullOrEmpty(id) && id.Length <= Protocol.MaxSourceIdLength && !id.Any(char.IsControl);

    public bool Contains(string deviceId, string sourceId)
    {
        lock (_gate) return Load(deviceId).Contains(sourceId);
    }

    /// <summary>The ids of <paramref name="ids"/> not received from <paramref name="deviceId"/> yet, in the order given, each once.</summary>
    public List<string> Missing(string deviceId, IEnumerable<string> ids)
    {
        lock (_gate)
        {
            var known = Load(deviceId);
            var seen = new HashSet<string>();
            return [.. ids.Where(id => !known.Contains(id) && seen.Add(id))];
        }
    }

    public void Add(string deviceId, string sourceId)
    {
        lock (_gate)
        {
            if (!Load(deviceId).Add(sourceId)) return;
            Directory.CreateDirectory(directory);
            File.AppendAllText(PathOf(deviceId), sourceId + "\n");
        }
    }

    /// <summary>Forgets what was received from the phone, so a gallery sync sends everything again.</summary>
    public void Clear(string deviceId)
    {
        lock (_gate)
        {
            _byDevice.Remove(deviceId);
            File.Delete(PathOf(deviceId));
        }
    }

    private HashSet<string> Load(string deviceId)
    {
        if (_byDevice.TryGetValue(deviceId, out var set)) return set;
        set = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            foreach (string line in File.ReadLines(PathOf(deviceId)))
            {
                if (line.Length > 0) set.Add(line);
            }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            // Nothing received yet.
        }
        _byDevice[deviceId] = set;
        return set;
    }

    private string PathOf(string deviceId) => Path.Combine(directory, deviceId + ".txt");
}
