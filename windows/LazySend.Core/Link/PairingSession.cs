using System.Net;
using System.Security.Cryptography;

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
/// pairing within <see cref="Lifetime"/>. Tokens are compared in constant time; a peer that sends
/// <see cref="MaxFailedAttempts"/> wrong ones is refused for the rest of the session, and
/// <see cref="MaxTotalFailedAttempts"/> wrong ones from anyone close it, so a token cannot be guessed. The
/// clock is passed in, so tests control it. Safe to use from any thread.
/// </summary>
public sealed class PairingSession
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(5);
    public const int MaxFailedAttempts = 5;
    public const int MaxTotalFailedAttempts = 25;

    private readonly object _gate = new();
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
        Opened = opened;
        Expires = opened + Lifetime;
    }

    /// <summary>The token as the pairing code carries it (base64url, 22 characters).</summary>
    public string Token { get; }

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

    /// <summary>Closes the session: no token is accepted any more.</summary>
    public void Close()
    {
        lock (_gate)
        {
            if (_state == PairingSessionState.Open) _state = PairingSessionState.Closed;
        }
    }
}
