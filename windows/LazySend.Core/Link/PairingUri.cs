using System.Globalization;
using System.Text;

namespace LazySend.Core;

/// <summary>Why a scanned code is not a pairing code this app can use.</summary>
public enum PairingUriErrorKind
{
    /// <summary>Not a Lazy Send pairing code at all (another app's QR code, a web address).</summary>
    NotPairingCode,
    /// <summary>A pairing code of a newer protocol version than this app speaks.</summary>
    NewerVersion,
    /// <summary>A Lazy Send pairing code with a missing or malformed part.</summary>
    Damaged,
}

/// <summary>A pairing code that cannot be used, with a message for the user.</summary>
public sealed class PairingUriException(PairingUriErrorKind kind, string message) : FormatException(message)
{
    public PairingUriErrorKind Kind { get; } = kind;
}

/// <summary>
/// What the desktop's QR code carries so a phone can pair with it, as a URI:
/// <c>lazysend://pair?v=1&amp;id=…&amp;n=…&amp;fp=…&amp;a=…&amp;p=…&amp;t=…</c>: the protocol
/// version, the desktop's id and name, its certificate's <see cref="SpkiFingerprint"/> (base64url),
/// the addresses it listens on (comma-separated, each percent-encoded), its port and the pairing
/// session's one-time token (base64url of 16 bytes). Values are percent-encoded UTF-8 (everything but
/// letters, digits and <c>-._~</c>); unknown parameters are ignored, so later versions can add some.
/// </summary>
public sealed record PairingUri(string DesktopId, string Name, string Fingerprint, IReadOnlyList<string> Addresses,
                                int Port, string Token)
{
    public const string Scheme = "lazysend";
    public const string Prefix = "lazysend://pair?";
    /// <summary>The longest code read, in UTF-8 bytes.</summary>
    public const int MaxLength = 2048;
    public const int MaxAddresses = 8;
    /// <summary>The longest address, in characters.</summary>
    public const int MaxAddressLength = 64;
    /// <summary>The longest desktop name, in UTF-8 bytes.</summary>
    public const int MaxNameBytes = 128;
    /// <summary>The token's length in bytes.</summary>
    public const int TokenByteCount = 16;

    public static string NotPairingCodeMessage => "This is not a Lazy Send pairing code.";
    public static string NewerVersionMessage =>
        "This pairing code is from a newer version of Lazy Send. Update the app on this phone, then scan it again.";
    public static string DamagedMessage =>
        "This pairing code could not be read. Show the code on the computer again and scan it once more.";

    /// <summary>The fingerprint's bytes; null when <see cref="Fingerprint"/> is not 32 bytes of base64url.</summary>
    public byte[]? FingerprintBytes =>
        Protocol.DecodeBase64Url(Fingerprint) is { Length: SpkiFingerprint.ByteCount } bytes ? bytes : null;

    /// <summary>The code as text. Throws <see cref="ArgumentException"/> for a code <see cref="Parse"/> would refuse.</summary>
    public string Format()
    {
        Validate(DesktopId, Name, Fingerprint, Addresses, Port, Token);
        var text = new StringBuilder(Prefix);
        text.Append("v=").Append(Protocol.Version.ToString(CultureInfo.InvariantCulture));
        text.Append("&id=").Append(PercentEncode(DesktopId));
        text.Append("&n=").Append(PercentEncode(Name));
        text.Append("&fp=").Append(PercentEncode(Fingerprint));
        if (Addresses.Count > 0) text.Append("&a=").Append(string.Join(",", Addresses.Select(PercentEncode)));
        text.Append("&p=").Append(Port.ToString(CultureInfo.InvariantCulture));
        text.Append("&t=").Append(PercentEncode(Token));
        return text.ToString();
    }

    public override string ToString() => Format();

    /// <summary>The pairing code in <paramref name="text"/>; throws <see cref="PairingUriException"/> when it cannot be used.</summary>
    public static PairingUri Parse(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxLength) throw Damaged();
        if (!text.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase))
        {
            throw new PairingUriException(PairingUriErrorKind.NotPairingCode, NotPairingCodeMessage);
        }
        // Only printable ASCII: percent-encoding covers everything else.
        if (!text.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) || !text.All(c => c > 0x20 && c < 0x7F)
            || text.Contains('#'))
        {
            throw Damaged();
        }
        // Each parameter as written (still percent-encoded): the address list is split at its
        // commas before its addresses are decoded.
        var raw = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string part in text[Prefix.Length..].Split('&'))
        {
            if (part.Length == 0) continue;
            int equals = part.IndexOf('=');
            string key = equals < 0 ? part : part[..equals];
            string value = equals < 0 ? "" : part[(equals + 1)..];
            if (key.Length == 0 || PercentDecode(value) is null || !raw.TryAdd(key, value)) throw Damaged();
        }
        string? Value(string key) => raw.TryGetValue(key, out string? value) ? PercentDecode(value) : null;
        // The version first: a newer code may have other parts this version would call damaged.
        if (Value("v") is not { } versionText || !IsDigits(versionText, 9)) throw Damaged();
        int version = int.Parse(versionText, NumberStyles.None, CultureInfo.InvariantCulture);
        if (version > Protocol.Version)
        {
            throw new PairingUriException(PairingUriErrorKind.NewerVersion, NewerVersionMessage);
        }
        if (version < 1) throw Damaged();
        if (Value("id") is not { } id || Value("n") is not { } name || Value("fp") is not { } fingerprint
            || Value("p") is not { } portText || Value("t") is not { } token)
        {
            throw Damaged();
        }
        var addresses = new List<string>();
        if (raw.TryGetValue("a", out string? addressList) && addressList.Length > 0)
        {
            foreach (string encoded in addressList.Split(','))
            {
                addresses.Add(PercentDecode(encoded) ?? throw Damaged());
            }
        }
        if (!IsDigits(portText, 5)) throw Damaged();
        int port = int.Parse(portText, NumberStyles.None, CultureInfo.InvariantCulture);
        try
        {
            Validate(id, name, fingerprint, addresses, port, token);
        }
        catch (ArgumentException)
        {
            throw Damaged();
        }
        return new PairingUri(id, name, fingerprint, addresses, port, token);
    }

    /// <summary>The pairing code in <paramref name="text"/>, or null with why not.</summary>
    public static PairingUri? TryParse(string text, out PairingUriException? error)
    {
        try
        {
            error = null;
            return Parse(text);
        }
        catch (PairingUriException e)
        {
            error = e;
            return null;
        }
    }

    public bool Equals(PairingUri? other) =>
        other is not null && DesktopId == other.DesktopId && Name == other.Name && Fingerprint == other.Fingerprint
        && Addresses.SequenceEqual(other.Addresses) && Port == other.Port && Token == other.Token;

    public override int GetHashCode() => HashCode.Combine(DesktopId, Fingerprint, Port, Token);

    /// <summary>
    /// Whether <paramref name="address"/> is an IP address a code may carry: IPv4 in dotted
    /// decimal (no leading zeros), or IPv6 (with "::", an embedded IPv4 tail and a zone after '%').
    /// </summary>
    public static bool IsValidAddress(string address)
    {
        if (address.Length == 0 || address.Length > MaxAddressLength) return false;
        return address.Contains(':') ? IsIPv6(address) : IsIPv4(address);
    }

    /// <summary>Everything but letters, digits and <c>-._~</c> as %XX of its UTF-8 bytes (uppercase hex).</summary>
    public static string PercentEncode(string value)
    {
        var text = new StringBuilder(value.Length);
        foreach (byte b in Encoding.UTF8.GetBytes(value))
        {
            if (b is >= (byte)'a' and <= (byte)'z' or >= (byte)'A' and <= (byte)'Z' or >= (byte)'0' and <= (byte)'9'
                or (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~')
            {
                text.Append((char)b);
            }
            else
            {
                text.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return text.ToString();
    }

    /// <summary>The text of a percent-encoded value; null for a bad escape, a character that must be escaped, or bytes that are not UTF-8.</summary>
    public static string? PercentDecode(string value)
    {
        var bytes = new List<byte>(value.Length);
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '%')
            {
                if (i + 2 >= value.Length || !IsHex(value[i + 1]) || !IsHex(value[i + 2])) return null;
                bytes.Add(byte.Parse(value.AsSpan(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                i += 2;
            }
            else if (c > 0x20 && c < 0x7F && c is not ('&' or '=' or '#' or '?'))
            {
                bytes.Add((byte)c);
            }
            else
            {
                return null;
            }
        }
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static PairingUriException Damaged() => new(PairingUriErrorKind.Damaged, DamagedMessage);

    private static void Validate(string id, string name, string fingerprint, IReadOnlyList<string> addresses, int port, string token)
    {
        if (!Protocol.IsValidId(id)) throw new ArgumentException("The desktop id is not valid.", nameof(id));
        if (name.Length == 0 || Encoding.UTF8.GetByteCount(name) > MaxNameBytes || HasControlCharacter(name))
        {
            throw new ArgumentException("The desktop name is empty, too long or has control characters.", nameof(name));
        }
        if (Protocol.DecodeBase64Url(fingerprint) is not { Length: SpkiFingerprint.ByteCount })
        {
            throw new ArgumentException("The fingerprint is not 32 bytes of base64url.", nameof(fingerprint));
        }
        if (addresses.Count > MaxAddresses || addresses.Any(a => !IsValidAddress(a)))
        {
            throw new ArgumentException("An address is not an IP address, or there are too many.", nameof(addresses));
        }
        if (port is < 1 or > 65535) throw new ArgumentException("The port is not 1 to 65535.", nameof(port));
        if (Protocol.DecodeBase64Url(token) is not { Length: TokenByteCount })
        {
            throw new ArgumentException("The token is not 16 bytes of base64url.", nameof(token));
        }
    }

    /// <summary>Any C0 or C1 control character, or DEL.</summary>
    internal static bool HasControlCharacter(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value is >= 0x7F and <= 0x9F) return true;
        }
        return false;
    }

    private static bool IsDigits(string text, int maxLength) =>
        text.Length > 0 && text.Length <= maxLength && text.All(c => c is >= '0' and <= '9');

    private static bool IsHex(char c) => c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F';

    private static bool IsIPv4(string text)
    {
        string[] parts = text.Split('.');
        if (parts.Length != 4) return false;
        foreach (string part in parts)
        {
            if (!IsDigits(part, 3) || (part.Length > 1 && part[0] == '0')) return false;
            if (int.Parse(part, NumberStyles.None, CultureInfo.InvariantCulture) > 255) return false;
        }
        return true;
    }

    private static bool IsIPv6(string text)
    {
        int percent = text.IndexOf('%');
        if (percent >= 0)
        {
            string zone = text[(percent + 1)..];
            if (zone.Length == 0 || zone.Length > 32
                || !zone.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_' or '.'))
            {
                return false;
            }
            text = text[..percent];
        }
        int compressed = text.IndexOf("::", StringComparison.Ordinal);
        if (compressed >= 0 && text.IndexOf("::", compressed + 1, StringComparison.Ordinal) >= 0) return false;
        string head = compressed >= 0 ? text[..compressed] : text;
        string tail = compressed >= 0 ? text[(compressed + 2)..] : "";
        int groups = 0;
        string[] headGroups = head.Length == 0 ? [] : head.Split(':');
        string[] tailGroups = tail.Length == 0 ? [] : tail.Split(':');
        var all = headGroups.Concat(tailGroups).ToList();
        for (int i = 0; i < all.Count; i++)
        {
            string group = all[i];
            bool last = i == all.Count - 1;
            if (last && group.Contains('.'))
            {
                if (!IsIPv4(group)) return false;
                groups += 2;
                continue;
            }
            if (group.Length is 0 or > 4 || !group.All(IsHex)) return false;
            groups++;
        }
        return compressed >= 0 ? groups <= 7 : groups == 8;
    }
}
