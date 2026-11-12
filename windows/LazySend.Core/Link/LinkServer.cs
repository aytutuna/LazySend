using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

namespace LazySend.Core;

public sealed record LinkServerOptions
{
    /// <summary>Connections served at once; more are closed at once.</summary>
    public int MaxConnections { get; init; } = 16;
    /// <summary>How many of those one address may hold, so that it cannot shut the phones out.</summary>
    public int MaxConnectionsPerPeer { get; init; } = 6;
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>How long the request line and headers may take to arrive.</summary>
    public TimeSpan HeadTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>How long a body may stall between two reads, and a response between two writes. A file upload has no other limit.</summary>
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromSeconds(30);
    /// <summary>How long a small body (pairing) may take in all, from its first read.</summary>
    public TimeSpan BodyTimeout { get; init; } = TimeSpan.FromSeconds(15);
    /// <summary>A refused request's unread body is read and dropped up to this size before closing.</summary>
    public long MaxDiscardBytes { get; init; } = 1024 * 1024;
    /// <summary>The whole time that dropping may take, however slowly the client sends.</summary>
    public TimeSpan DiscardTimeout { get; init; } = TimeSpan.FromSeconds(5);
    /// <summary>Which peers are answered (others are closed before TLS); every peer when null.</summary>
    public Func<IPAddress, bool>? AllowPeer { get; init; }
    /// <summary>When stopping, how long requests already being served may take to finish before they are cut off.</summary>
    public TimeSpan StopGrace { get; init; } = TimeSpan.FromSeconds(2);
}

/// <summary>
/// The phone link server: TLS 1.2/1.3 over TCP with the desktop's own certificate, one request per
/// connection, the small HTTP/1.1 subset of <see cref="LinkHttp"/>, every request handed to
/// <see cref="LinkRouter"/>. One dual-stack listener takes every interface, wired ones included.
/// Peers that <see cref="LinkServerOptions.AllowPeer"/> refuses or <see cref="LinkRateLimiter"/>
/// blocks are closed before TLS, and every step is bounded in time.
/// </summary>
public sealed class LinkServer : IAsyncDisposable
{
    private readonly X509Certificate2 _certificate;
    private readonly LinkRouter _router;
    private readonly LinkRateLimiter _limiter;
    private readonly LinkServerOptions _options;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Dictionary<Task, IPAddress> _connections = [];
    private readonly object _gate = new();
    private TcpListener? _listener;
    private Task? _acceptLoop;
    private CancellationTokenSource? _accept;
    private CancellationTokenSource? _stop;
    private SslStreamCertificateContext? _context;

    public LinkServer(X509Certificate2 certificate, LinkRouter router, LinkRateLimiter limiter,
                      LinkServerOptions? options = null, Func<DateTimeOffset>? clock = null)
    {
        if (!certificate.HasPrivateKey) throw new ArgumentException("The server certificate needs its private key.", nameof(certificate));
        _certificate = certificate;
        _router = router;
        _limiter = limiter;
        _options = options ?? new LinkServerOptions();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public bool IsRunning => _stop is not null;

    /// <summary>The port listened on; 0 when stopped.</summary>
    public int Port { get; private set; }

    public int ActiveConnections
    {
        get
        {
            lock (_gate) return _connections.Count;
        }
    }

    /// <summary>
    /// Starts listening on <paramref name="port"/> (the system picks one when it is 0 or taken) on
    /// every interface, IPv4 and IPv6, or only on <paramref name="address"/> when given. Returns the port.
    /// </summary>
    public int Start(int port = Protocol.DefaultPort, IPAddress? address = null)
    {
        if (IsRunning) throw new InvalidOperationException("The server is already running.");
        _context ??= SslStreamCertificateContext.Create(_certificate, additionalCertificates: null, offline: true);
        var listener = Bind(address, port);
        _listener = listener;
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _stop = new CancellationTokenSource();
        _accept = new CancellationTokenSource();
        var accept = _accept.Token;
        var stop = _stop.Token;
        _acceptLoop = Task.Run(() => AcceptLoopAsync(listener, accept, stop));
        return Port;
    }

    private static TcpListener Bind(IPAddress? address, int port)
    {
        try
        {
            return Listen(address, port);
        }
        catch (SocketException) when (port != 0)
        {
            return Listen(address, 0);
        }
    }

    private static TcpListener Listen(IPAddress? address, int port)
    {
        TcpListener listener;
        if (address is not null)
        {
            listener = new TcpListener(address, port);
        }
        else if (Socket.OSSupportsIPv6)
        {
            listener = new TcpListener(IPAddress.IPv6Any, port);
            listener.Server.DualMode = true;
        }
        else
        {
            listener = new TcpListener(IPAddress.Any, port);
        }
        listener.Server.ExclusiveAddressUse = true;
        listener.Start(backlog: 32);
        return listener;
    }

    /// <summary>
    /// Stops listening at once, lets the requests being served finish for
    /// <see cref="LinkServerOptions.StopGrace"/>, then cuts off the rest.
    /// </summary>
    public async Task StopAsync()
    {
        var stop = _stop;
        var accept = _accept;
        if (stop is null || accept is null) return;
        _stop = null;
        _accept = null;
        accept.Cancel();
        _listener?.Stop();
        _listener = null;
        Task[] serving;
        lock (_gate) serving = [.. _connections.Keys];
        try
        {
            await Task.WhenAll(serving).WaitAsync(_options.StopGrace).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Cut off below.
        }
        stop.Cancel();
        Task[] pending;
        lock (_gate) pending = [.. _connections.Keys];
        try
        {
            if (_acceptLoop is { } loop) await loop.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (Exception e) when (e is TimeoutException or OperationCanceledException)
        {
            System.Diagnostics.Trace.TraceWarning($"Phone link connections did not end in time: {e.Message}");
        }
        Port = 0;
        stop.Dispose();
        accept.Dispose();
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken accept, CancellationToken stop)
    {
        while (!accept.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(accept).ConfigureAwait(false);
            }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException
                                          or InvalidOperationException)
            {
                if (accept.IsCancellationRequested) return;
                // A connection reset while it was being accepted is no reason to stop accepting.
                if (e is SocketException { SocketErrorCode: SocketError.ConnectionReset or SocketError.ConnectionAborted
                                                            or SocketError.Interrupted or SocketError.TimedOut
                                                            or SocketError.TooManyOpenSockets or SocketError.NoBufferSpaceAvailable })
                {
                    try
                    {
                        await Task.Delay(100, accept).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }
                    continue;
                }
                System.Diagnostics.Trace.TraceWarning($"The phone link listener stopped: {e.Message}");
                return;
            }
            var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.None;
            var peer = LocalSubnet.Normalize(remote);
            Task connection;
            // Counted before the lock is left: one peer can be in several accepts at once.
            lock (_gate)
            {
                if (_connections.Count >= _options.MaxConnections
                    || _connections.Values.Count(held => held.Equals(peer)) >= _options.MaxConnectionsPerPeer
                    || (_options.AllowPeer is { } allow && !allow(remote))
                    || _limiter.IsBlocked(remote, _clock()))
                {
                    client.Dispose();
                    continue;
                }
                connection = ServeAsync(client, remote, stop);
                _connections.Add(connection, peer);
            }
            _ = connection.ContinueWith(done =>
            {
                lock (_gate) _connections.Remove(done);
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    private async Task ServeAsync(TcpClient client, IPAddress remote, CancellationToken stop)
    {
        await Task.Yield();
        using var tcp = client;
        tcp.NoDelay = true;
        try
        {
            await using var tls = new SslStream(tcp.GetStream(), leaveInnerStreamOpen: false);
            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(stop))
            {
                handshake.CancelAfter(_options.HandshakeTimeout);
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificateContext = _context,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    ClientCertificateRequired = false,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                }, handshake.Token).ConfigureAwait(false);
            }
            await ServeRequestAsync(tls, tcp.Client, remote, stop).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or AuthenticationException or OperationCanceledException
                                      or ObjectDisposedException or SocketException or InvalidOperationException)
        {
            // A client that went away, timed out or failed the handshake: nothing to answer.
        }
    }

    private async Task ServeRequestAsync(SslStream tls, Socket socket, IPAddress remote, CancellationToken stop)
    {
        var buffer = new byte[LinkHttp.MaxHeadBytes + 4096];
        int filled = 0;
        HttpParseResult parsed;
        using (var headTimeout = CancellationTokenSource.CreateLinkedTokenSource(stop))
        {
            headTimeout.CancelAfter(_options.HeadTimeout);
            while (true)
            {
                int read = await tls.ReadAsync(buffer.AsMemory(filled), headTimeout.Token).ConfigureAwait(false);
                if (read == 0) return;
                filled += read;
                parsed = LinkHttp.Parse(buffer.AsSpan(0, filled));
                if (parsed.Status != HttpParseStatus.Incomplete) break;
                if (filled == buffer.Length)
                {
                    parsed = new HttpParseResult(HttpParseStatus.Invalid, ErrorStatus: 431);
                    break;
                }
            }
        }
        if (parsed.Status == HttpParseStatus.Invalid || parsed.Head is not { } head)
        {
            await WriteAsync(tls, LinkResponse.Error(parsed.ErrorStatus, LinkError.BadRequest), stop).ConfigureAwait(false);
            return;
        }

        var idle = new IdleStream(tls, _options.IdleTimeout);
        var timed = new BodyGuard(idle, head.ContentLength is <= Protocol.MaxSmallBodyBytes, _options);
        var body = new LinkRequestBody(
            timed, head.ContentLength ?? 0, buffer.AsMemory(parsed.Consumed, filled - parsed.Consumed),
            head.ExpectsContinue ? token => idle.WriteAsync(LinkHttp.ContinueResponse.ToArray(), token).AsTask() : null);
        LinkResponse response;
        try
        {
            response = await _router.HandleAsync(new LinkRequest(head, body, remote), stop).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not (IOException or OperationCanceledException))
        {
            // A connection that broke or timed out ends quietly (above); anything else is a bug, answered 500.
            System.Diagnostics.Trace.TraceError($"A phone link request failed: {e}");
            response = LinkResponse.Error(500, LinkError.ServerError);
        }
        bool written = false;
        try
        {
            // A write into a closed socket still succeeds once; a phone that already hung up never gets the secret.
            if (response.Written is null || !(socket.Poll(0, SelectMode.SelectRead) && socket.Available == 0))
            {
                await WriteAsync(idle, response, stop).ConfigureAwait(false);
                written = true;
            }
        }
        finally
        {
            response.Stream?.Dispose();
            response.Written?.Invoke(written);
        }
        // Leave the client its whole send when it is small, so closing does not cut off the answer.
        using var discard = CancellationTokenSource.CreateLinkedTokenSource(stop);
        discard.CancelAfter(_options.DiscardTimeout);
        await body.DiscardAsync(_options.MaxDiscardBytes, discard.Token).ConfigureAwait(false);
    }

    private static async Task WriteAsync(Stream stream, LinkResponse response, CancellationToken stop)
    {
        await stream.WriteAsync(LinkHttp.ResponseHead(response.Status, response.Headers, response.ContentLength), stop).ConfigureAwait(false);
        if (response.Stream is { } source)
        {
            var buffer = new byte[256 * 1024];
            long left = response.ContentLength;
            while (left > 0)
            {
                int read = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, left)), stop).ConfigureAwait(false);
                if (read == 0) throw new IOException("The file ended before its announced length.");
                await stream.WriteAsync(buffer.AsMemory(0, read), stop).ConfigureAwait(false);
                left -= read;
            }
        }
        else if (response.Body.Length > 0)
        {
            await stream.WriteAsync(response.Body, stop).ConfigureAwait(false);
        }
        await stream.FlushAsync(stop).ConfigureAwait(false);
    }

    /// <summary>The connection as the body's source: a small body has <see cref="LinkServerOptions.BodyTimeout"/> in all. Reads only.</summary>
    private sealed class BodyGuard(Stream inner, bool small, LinkServerOptions options) : Stream
    {
        private long? _started;

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (!small) return await inner.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            long now = Environment.TickCount64;
            long started = _started ??= now;
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var left = options.BodyTimeout - TimeSpan.FromMilliseconds(now - started);
            limit.CancelAfter(left > TimeSpan.Zero ? left : TimeSpan.Zero);
            return await inner.ReadAsync(buffer, limit.Token).ConfigureAwait(false);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    /// <summary>The connection, with each read and write given at most the idle timeout.</summary>
    private sealed class IdleStream(Stream inner, TimeSpan idle) : Stream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(idle);
            return await inner.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
        }

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(idle);
            await inner.WriteAsync(buffer, timeout.Token).ConfigureAwait(false);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => inner.Flush();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
