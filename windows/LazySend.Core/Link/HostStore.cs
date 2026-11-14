using System.Security.Cryptography;

namespace LazySend.Core;

/// <summary>A computer this one is paired with as a guest (an entry of hosts.json).</summary>
public sealed class GuestHost
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    /// <summary>The certificate's <see cref="SpkiFingerprint"/>, base64url.</summary>
    public string Fingerprint { get; set; } = "";
    public List<string> Addresses { get; set; } = [];
    public int Port { get; set; }
    public string? LastAddress { get; set; }
    /// <summary>The secret as DPAPI protected it for this user, base64.</summary>
    public string ProtectedSecret { get; set; } = "";
    public DateTimeOffset? Paired { get; set; }

    internal GuestHost Copy()
    {
        var copy = (GuestHost)MemberwiseClone();
        copy.Addresses = [.. Addresses];
        return copy;
    }
}

public sealed class HostsFile
{
    public List<GuestHost> Hosts { get; set; } = [];
}

/// <summary>
/// The computers this one is paired with as a guest, in hosts.json next to devices.json. The secret a
/// host gave is kept protected for the current Windows user; a copy of the file on another account or
/// PC cannot read it. Safe to use from any thread.
/// </summary>
public sealed class HostStore
{
    public const int MaxHosts = 16;

    private readonly string _path;
    private readonly object _gate = new();
    private readonly HostsFile _file;

    public HostStore(string path)
    {
        _path = path;
        _file = JsonFile.Load<HostsFile>(path);
    }

    public event EventHandler? Changed;

    /// <summary>Raised with the host's id after it was removed.</summary>
    public event EventHandler<string>? Removed;

    public IReadOnlyList<GuestHost> Hosts
    {
        get
        {
            lock (_gate) return [.. _file.Hosts.Select(h => h.Copy())];
        }
    }

    public GuestHost? Find(string id)
    {
        lock (_gate) return _file.Hosts.FirstOrDefault(h => h.Id == id)?.Copy();
    }

    /// <summary>Keeps <paramref name="host"/> with its <paramref name="secret"/> (pairing again replaces the entry). Throws <see cref="InvalidOperationException"/> when <see cref="MaxHosts"/> others are kept and <see cref="IOException"/> when it cannot be saved.</summary>
    public void Add(GuestHost host, string secret)
    {
        host.ProtectedSecret = Convert.ToBase64String(Protect(Protocol.DecodeBase64Url(secret)!));
        lock (_gate)
        {
            var others = _file.Hosts.Where(h => h.Id != host.Id).ToList();
            if (others.Count >= MaxHosts) throw new InvalidOperationException("Too many computers are paired.");
            var previous = _file.Hosts;
            _file.Hosts = [.. others, host.Copy()];
            try
            {
                JsonFile.Save(_path, _file);
            }
            catch
            {
                _file.Hosts = previous;
                throw;
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The host's secret, base64url; null when it is not kept or cannot be unprotected by this user.</summary>
    public string? Secret(string id)
    {
        string protectedSecret;
        lock (_gate)
        {
            if (_file.Hosts.FirstOrDefault(h => h.Id == id) is not { } host) return null;
            protectedSecret = host.ProtectedSecret;
        }
        try
        {
            return Protocol.EncodeBase64Url(Unprotect(Convert.FromBase64String(protectedSecret)));
        }
        catch (Exception e) when (e is CryptographicException or FormatException)
        {
            return null;
        }
    }

    /// <summary>Changes the host's entry with <paramref name="change"/> and saves; a failed save is dropped, the entry is rewritten with the next change.</summary>
    public void Update(string id, Action<GuestHost> change)
    {
        lock (_gate)
        {
            if (_file.Hosts.FirstOrDefault(h => h.Id == id) is not { } host) return;
            change(host);
            try
            {
                JsonFile.Save(_path, _file);
            }
            catch (IOException)
            {
                // Only the address list or name is lost.
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public bool Remove(string id)
    {
        bool removed;
        lock (_gate)
        {
            removed = _file.Hosts.RemoveAll(h => h.Id == id) > 0;
            if (removed) JsonFile.Save(_path, _file);
        }
        if (removed)
        {
            Removed?.Invoke(this, id);
            Changed?.Invoke(this, EventArgs.Empty);
        }
        return removed;
    }

    private static byte[] Protect(byte[] secret) =>
        OperatingSystem.IsWindows() ? ProtectedData.Protect(secret, null, DataProtectionScope.CurrentUser) : throw new PlatformNotSupportedException();

    private static byte[] Unprotect(byte[] secret) =>
        OperatingSystem.IsWindows() ? ProtectedData.Unprotect(secret, null, DataProtectionScope.CurrentUser) : throw new PlatformNotSupportedException();

    /// <summary>What <c>hello</c> lists goes first, then what was known; scoped addresses cannot go in a URL, so they are left out.</summary>
    public static List<string> MergeAddresses(IEnumerable<string> fromHello, IEnumerable<string> known) =>
        [.. fromHello.Concat(known).Where(a => !a.Contains('%')).Distinct().Take(PairingUri.MaxAddresses)];
}
