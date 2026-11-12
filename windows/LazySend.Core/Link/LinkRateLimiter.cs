using System.Net;

namespace LazySend.Core;

public sealed class LinkRateLimiter
{
    public const int MaxFailures = 10;
    public const int MaxRequestsPerWindow = 3000;
    public const int MaxTrackedAddresses = 1024;
    public static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    private readonly object _gate = new();
    private readonly Dictionary<IPAddress, Entry> _entries = [];

    private sealed class Entry
    {
        public readonly Queue<DateTimeOffset> Failures = new();
        public readonly Queue<DateTimeOffset> Requests = new();
        public DateTimeOffset LastUsed;
    }

    /// <summary>Whether <paramref name="address"/> is refused at <paramref name="now"/> for its failures.</summary>
    public bool IsBlocked(IPAddress address, DateTimeOffset now)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(Normalize(address), out var entry)) return false;
            Prune(entry.Failures, now);
            return entry.Failures.Count >= MaxFailures;
        }
    }

    /// <summary>Counts a request; false when <paramref name="address"/> is over its limit or blocked.</summary>
    public bool TryRequest(IPAddress address, DateTimeOffset now)
    {
        lock (_gate)
        {
            var entry = EntryFor(Normalize(address), now);
            Prune(entry.Failures, now);
            Prune(entry.Requests, now);
            if (entry.Failures.Count >= MaxFailures || entry.Requests.Count >= MaxRequestsPerWindow) return false;
            entry.Requests.Enqueue(now);
            return true;
        }
    }

    /// <summary>Counts a failed authentication or pairing token from <paramref name="address"/>.</summary>
    public void RecordFailure(IPAddress address, DateTimeOffset now)
    {
        lock (_gate)
        {
            var entry = EntryFor(Normalize(address), now);
            Prune(entry.Failures, now);
            entry.Failures.Enqueue(now);
            while (entry.Failures.Count > MaxFailures) entry.Failures.Dequeue();
        }
    }

    private Entry EntryFor(IPAddress address, DateTimeOffset now)
    {
        if (!_entries.TryGetValue(address, out var entry))
        {
            if (_entries.Count >= MaxTrackedAddresses)
            {
                var oldest = _entries.MinBy(pair => pair.Value.LastUsed).Key;
                _entries.Remove(oldest);
            }
            entry = new Entry();
            _entries[address] = entry;
        }
        entry.LastUsed = now;
        return entry;
    }

    private static void Prune(Queue<DateTimeOffset> times, DateTimeOffset now)
    {
        while (times.Count > 0 && (now - times.Peek() >= Window || times.Peek() > now)) times.Dequeue();
    }

    private static IPAddress Normalize(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
}
