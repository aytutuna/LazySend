using System.Security.Cryptography;
using System.Text;

namespace LazySend.Core;

/// <summary>A phone paired with this desktop (an entry of devices.json).</summary>
public sealed class PairedDevice
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    /// <summary>"ios", "android"…, as the phone said.</summary>
    public string Platform { get; set; } = "";
    public string AppVersion { get; set; } = "";
    /// <summary>
    /// SHA-256 of the phone's secret, lowercase hex. The secret itself is never stored: a copy of this
    /// file does not let anyone pose as the phone.
    /// </summary>
    public string SecretHash { get; set; } = "";
    public DateTimeOffset? Paired { get; set; }
    public DateTimeOffset? LastSeen { get; set; }

    internal PairedDevice Copy() => (PairedDevice)MemberwiseClone();
}

public sealed class DevicesFile
{
    /// <summary>This desktop's id for phones (32 hex digits), made on first use.</summary>
    public string DesktopId { get; set; } = "";
    public List<PairedDevice> Devices { get; set; } = [];
}

/// <summary>
/// The phones paired with this desktop. Pairing makes a random 256-bit secret, hands it to the phone
/// once and keeps only its SHA-256; a request is accepted when its device id and secret match an
/// entry. Safe to use from any thread.
/// </summary>
public sealed class PairedDeviceStore
{
    public const int SecretByteCount = 32;
    public const int MaxDevices = 16;
    /// <summary>A phone's last-seen time is written at most this often.</summary>
    public static readonly TimeSpan LastSeenResolution = TimeSpan.FromMinutes(1);

    private readonly string _path;
    private readonly object _gate = new();
    private readonly DevicesFile _file;

    public PairedDeviceStore(string path)
    {
        _path = path;
        _file = JsonFile.Load<DevicesFile>(path);
        if (!Protocol.IsValidId(_file.DesktopId))
        {
            _file.DesktopId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
            JsonFile.Save(_path, _file);
        }
    }

    /// <summary>Raised after a phone was paired or removed (on the thread that changed it).</summary>
    public event EventHandler? Changed;

    public string DesktopId => _file.DesktopId;

    /// <summary>The paired phones (copies), in the order they were paired.</summary>
    public IReadOnlyList<PairedDevice> Devices
    {
        get
        {
            lock (_gate) return [.. _file.Devices.Select(d => d.Copy())];
        }
    }

    /// <summary>
    /// Pairs the phone <paramref name="id"/> (pairing again replaces its entry and secret) and returns
    /// its new secret, base64url of 32 bytes, to be sent to the phone once. Throws
    /// <see cref="InvalidOperationException"/> when <see cref="MaxDevices"/> other phones are paired and
    /// <see cref="IOException"/> when the pairing cannot be saved: a phone must not believe it is paired when it is not.
    /// </summary>
    public string Pair(string id, string name, string platform, string appVersion, DateTimeOffset now)
    {
        if (!Protocol.IsValidId(id)) throw new ArgumentException("The phone's id is not valid.", nameof(id));
        byte[] secret = RandomNumberGenerator.GetBytes(SecretByteCount);
        lock (_gate)
        {
            var others = _file.Devices.Where(d => d.Id != id).ToList();
            if (others.Count >= MaxDevices) throw new InvalidOperationException("Too many phones are paired.");
            var previous = _file.Devices;
            _file.Devices =
            [
                .. others,
                new PairedDevice
                {
                    Id = id,
                    Name = CleanName(name),
                    Platform = CleanName(platform),
                    AppVersion = CleanName(appVersion),
                    SecretHash = HashSecret(secret),
                    Paired = now,
                    LastSeen = now,
                },
            ];
            try
            {
                JsonFile.Save(_path, _file);
            }
            catch
            {
                _file.Devices = previous;
                throw;
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return Protocol.EncodeBase64Url(secret);
    }

    /// <summary>The paired phone <paramref name="id"/> when <paramref name="secret"/> is its secret (compared in constant time); null otherwise.</summary>
    public PairedDevice? Authenticate(string? id, string? secret, DateTimeOffset now)
    {
        if (!Protocol.IsValidId(id) || Protocol.DecodeBase64Url(secret) is not { Length: SecretByteCount } bytes) return null;
        byte[] presented = SHA256.HashData(bytes);
        lock (_gate)
        {
            var device = _file.Devices.FirstOrDefault(d => d.Id == id);
            if (device is null || device.SecretHash.Length != 64) return null;
            byte[] stored;
            try
            {
                stored = Convert.FromHexString(device.SecretHash);
            }
            catch (FormatException)
            {
                return null;
            }
            if (!CryptographicOperations.FixedTimeEquals(presented, stored)) return null;
            if (device.LastSeen is not { } seen || now - seen >= LastSeenResolution || now < seen)
            {
                device.LastSeen = now;
                try
                {
                    JsonFile.Save(_path, _file);
                }
                catch (IOException)
                {
                    // Only the last-seen time is lost.
                }
            }
            return device.Copy();
        }
    }

    /// <summary>Unpairs the phone <paramref name="id"/>; it is refused from now on. False when it was not paired.</summary>
    public bool Remove(string id)
    {
        bool removed;
        lock (_gate)
        {
            removed = _file.Devices.RemoveAll(d => d.Id == id) > 0;
            if (removed) JsonFile.Save(_path, _file);
        }
        if (removed) Changed?.Invoke(this, EventArgs.Empty);
        return removed;
    }

    public static string HashSecret(ReadOnlySpan<byte> secret) => Convert.ToHexStringLower(SHA256.HashData(secret));

    /// <summary>A name as kept: control characters removed, trimmed, cut to <see cref="PairRequest.MaxNameBytes"/> UTF-8 bytes.</summary>
    public static string CleanName(string? name)
    {
        var text = new StringBuilder();
        int bytes = 0;
        foreach (var rune in (name ?? "").EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value is >= 0x7F and <= 0x9F) continue;
            if (bytes + rune.Utf8SequenceLength > PairRequest.MaxNameBytes) break;
            bytes += rune.Utf8SequenceLength;
            text.Append(rune.ToString());
        }
        return text.ToString().Trim();
    }
}
