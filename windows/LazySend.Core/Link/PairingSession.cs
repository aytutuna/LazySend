using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace LazySend.Core;

/// <summary>Where a pairing session is.</summary>
public enum PairingSessionState
{
    /// <summary>Waiting for a phone to present the token.</summary>
    Open,
    /// <summary>A phone presented the token; it cannot be used again.</summary>
    Used,
    /// <summary>Its five minutes are over.</summary>
    Expired,
    /// <summary>Closed by the desktop, or after too many wrong tokens from all peers together.</summary>
    Closed,
}

/// <summary>The answer to a token presented to a pairing session.</summary>
public enum PairingRedeemResult
{
    Accepted,
    WrongToken,
    Expired,
    AlreadyUsed,
    Closed,
}

/// <summary>
/// One pairing window on the desktop: a random 128-bit token shown in the QR code, good for one
/// pairing within <see cref="Lifetime"/>, and the session's 8-character <see cref="ShortCode"/> for a
/// guest that cannot scan. Either is compared in constant time; a peer that sends
/// <see cref="MaxFailedAttempts"/> wrong ones is refused for the rest of the session, and
/// <see cref="MaxTotalFailedAttempts"/> wrong ones from anyone close it, so neither can be guessed. The
/// clock is passed in, so tests control it. Safe to use from any thread.
/// </summary>
public sealed class PairingSession
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(5);
    public const int MaxFailedAttempts = 5;
    public const int MaxTotalFailedAttempts = 25;

    private readonly object _gate = new();
    public const int ShortCodeLength = 8;
    private const string CodeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    private readonly byte[] _token;
    private PairingSessionState _state = PairingSessionState.Open;
    private readonly Dictionary<IPAddress, int> _failedByPeer = [];
    private int _failedAttempts;

    /// <param name="opened">When the session opens; it expires <see cref="Lifetime"/> later.</param>
    /// <param name="token">The token's 16 bytes; random when null (tests pass their own).</param>
    public PairingSession(DateTimeOffset opened, byte[]? token = null)
    {
        if (token is not null && token.Length != PairingUri.TokenByteCount)
        {
            throw new ArgumentException("A pairing token has 16 bytes.", nameof(token));
        }
        _token = token ?? RandomNumberGenerator.GetBytes(PairingUri.TokenByteCount);
        Token = Protocol.EncodeBase64Url(_token);
        // 256 is a multiple of 32, so masking a random byte is unbiased.
        ShortCode = string.Create(ShortCodeLength, 0, (chars, _) =>
        {
            var random = RandomNumberGenerator.GetBytes(ShortCodeLength);
            for (int i = 0; i < chars.Length; i++) chars[i] = CodeAlphabet[random[i] & 31];
        });
        Opened = opened;
        Expires = opened + Lifetime;
    }

    /// <summary>The token as the pairing code carries it (base64url, 22 characters).</summary>
    public string Token { get; }

    /// <summary>The short code: 8 characters of Crockford base32, no separator.</summary>
    public string ShortCode { get; }

    /// <summary>The short code as shown, XXXX-XXXX.</summary>
    public string ShortCodeText => $"{ShortCode[..4]}-{ShortCode[4..]}";

    public DateTimeOffset Opened { get; }

    public DateTimeOffset Expires { get; }

    public int FailedAttempts
    {
        get
        {
            lock (_gate) return _failedAttempts;
        }
    }

    /// <summary>Where the session is at <paramref name="now"/>.</summary>
    public PairingSessionState StateAt(DateTimeOffset now)
    {
        lock (_gate)
        {
            return _state == PairingSessionState.Open && now >= Expires ? PairingSessionState.Expired : _state;
        }
    }

    /// <summary>How long the session stays open after <paramref name="now"/>; zero once it is not open.</summary>
    public TimeSpan Remaining(DateTimeOffset now) =>
        StateAt(now) == PairingSessionState.Open ? Expires - now : TimeSpan.Zero;

    /// <summary>
    /// Presents <paramref name="token"/> from <paramref name="peer"/> at <paramref name="now"/>. The
    /// right token while the session is open is accepted once; a wrong one counts against its peer
    /// (<see cref="MaxFailedAttempts"/>, after which that peer gets <see cref="PairingRedeemResult.Closed"/>
    /// for the session) and against the total (<see cref="MaxTotalFailedAttempts"/>, after which the
    /// session is closed). Callers that do not know the peer pass none, and count as one.
    /// </summary>
    public PairingRedeemResult Redeem(string? token, DateTimeOffset now, IPAddress? peer = null)
    {
        lock (_gate)
        {
            switch (_state)
            {
                case PairingSessionState.Used:
                    return PairingRedeemResult.AlreadyUsed;
                case PairingSessionState.Closed:
                    return PairingRedeemResult.Closed;
            }
            if (now >= Expires)
            {
                _state = PairingSessionState.Expired;
                return PairingRedeemResult.Expired;
            }
            if (_state == PairingSessionState.Expired) return PairingRedeemResult.Expired;
            var key = peer is null ? IPAddress.None : LocalSubnet.Normalize(peer);
            int byPeer = _failedByPeer.GetValueOrDefault(key);
            if (byPeer >= MaxFailedAttempts) return PairingRedeemResult.Closed;
            byte[]? presented = Protocol.DecodeBase64Url(token);
            bool matches = presented is { Length: PairingUri.TokenByteCount }
                           && CryptographicOperations.FixedTimeEquals(presented, _token);
            if (NormalizeShortCode(token) is { } code)
            {
                matches = CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(code), Encoding.ASCII.GetBytes(ShortCode));
            }
            if (!matches)
            {
                _failedAttempts++;
                _failedByPeer[key] = byPeer + 1;
                if (_failedAttempts >= MaxTotalFailedAttempts) _state = PairingSessionState.Closed;
                return PairingRedeemResult.WrongToken;
            }
            _state = PairingSessionState.Used;
            return PairingRedeemResult.Accepted;
        }
    }

    /// <summary>
    /// A short code as typed (any case, with dashes or spaces) in its canonical form; null when it is not
    /// 8 characters of the alphabet, which also tells it from a 22-character token.
    /// </summary>
    public static string? NormalizeShortCode(string? text)
    {
        if (text is null || text.Length > 32) return null;
        var code = new StringBuilder(ShortCodeLength);
        foreach (char c in text)
        {
            if (c is '-' or ' ') continue;
            char upper = c is >= 'a' and <= 'z' ? (char)(c - 32) : c;
            if (CodeAlphabet.IndexOf(upper) < 0) return null;
            code.Append(upper);
        }
        return code.Length == ShortCodeLength ? code.ToString() : null;
    }

    /// <summary>Closes the session: no token is accepted any more.</summary>
    public void Close()
    {
        lock (_gate)
        {
            if (_state == PairingSessionState.Open) _state = PairingSessionState.Closed;
        }
    }
}
