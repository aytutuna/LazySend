using System.Net;
using System.Security.Cryptography.X509Certificates;

namespace LazySend.Core;

/// <summary>
/// The desktop's side of the phone link, put together: the paired phones, what they sent, what waits
/// for them and the server. The app adds the certificate, the DNS-SD advertisement, the approval prompt
/// and its windows; everything here runs without a screen, so the tests drive it over loopback.
/// </summary>
public sealed class LinkService : IAsyncDisposable
{
    private readonly X509Certificate2 _certificate;
    private readonly Func<DateTimeOffset> _clock;
    private PairingSession? _pairing;

    public LinkService(SendPaths paths, X509Certificate2 certificate, LinkServerOptions? serverOptions = null,
                       Func<DateTimeOffset>? clock = null, Func<string, long>? freeSpace = null)
    {
        _certificate = certificate;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Settings = new SendSettings(paths);
        Devices = new PairedDeviceStore(paths.DevicesFile);
        Gallery = new GalleryIndex(paths.IndexDirectory);
        History = new ReceivedHistory(paths.HistoryFile);
        Outbox = new Outbox(paths.OutboxFile, _clock);
        Inbox = new Inbox(paths.IncomingDirectory, () => Settings.ReceiveRoot, Gallery, freeSpace, _clock);
        Limiter = new LinkRateLimiter();
        Router = new LinkRouter(Devices, Inbox, History, Outbox, Gallery, Limiter, _clock) { CurrentPairing = () => Pairing };
        Server = new LinkServer(certificate, Router, Limiter, serverOptions ?? new LinkServerOptions { AllowPeer = LocalNetworks.IsAllowedPeer }, _clock);
    }

    public SendSettings Settings { get; }
    public PairedDeviceStore Devices { get; }
    public GalleryIndex Gallery { get; }
    public ReceivedHistory History { get; }
    public Outbox Outbox { get; }
    public Inbox Inbox { get; }
    public LinkRateLimiter Limiter { get; }
    public LinkRouter Router { get; }
    public LinkServer Server { get; }

    /// <summary>The certificate's fingerprint: the pin phones keep.</summary>
    public byte[] Fingerprint => SpkiFingerprint.Of(_certificate);

    /// <summary>The pairing session open now; null when none is (closed, used, or expired).</summary>
    public PairingSession? Pairing
    {
        get
        {
            var session = _pairing;
            return session is not null && session.StateAt(_clock()) == PairingSessionState.Open ? session : null;
        }
    }

    /// <summary>Starts the server on <paramref name="port"/>, or another free one; returns the port.</summary>
    public int Start(int port = Protocol.DefaultPort, IPAddress? address = null) => Server.Start(port, address);

    public Task StopAsync() => Server.StopAsync();

    /// <summary>
    /// Opens a pairing session (replacing any open one) and returns what the QR code carries. The
    /// server must be running; <paramref name="addresses"/> default to the computer's own (<see cref="LocalNetworks.PairingAddresses()"/>).
    /// </summary>
    public PairingUri OpenPairing(IReadOnlyList<string>? addresses = null)
    {
        if (!Server.IsRunning) throw new InvalidOperationException("The server is not running.");
        _pairing?.Close();
        var session = new PairingSession(_clock());
        _pairing = session;
        string name = PairedDeviceStore.CleanName(Router.DesktopName());
        return new PairingUri(Devices.DesktopId, name.Length > 0 ? name : "Computer", SpkiFingerprint.Text(Fingerprint),
                              addresses ?? LocalNetworks.PairingAddresses(), Server.Port, session.Token);
    }

    public void ClosePairing() => _pairing?.Close();

    public async ValueTask DisposeAsync() => await Server.DisposeAsync().ConfigureAwait(false);
}
