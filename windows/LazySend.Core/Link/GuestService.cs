namespace LazySend.Core;

/// <summary>
/// This computer's side as a guest of other computers: pairing with them, sending to them, and taking what they
/// queue while the app runs. A host that does not answer is tried again quietly, a little later each time; one
/// that no longer knows this computer is dropped. Events are raised on whatever thread saw them.
/// </summary>
public sealed class GuestService : IDisposable
{
    private static readonly TimeSpan FirstRetry = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan LastRetry = TimeSpan.FromSeconds(60);

    private readonly string _guestId;
    private readonly string _guestName;
    private readonly string _appVersion;
    private readonly object _gate = new();
    private readonly Dictionary<string, CancellationTokenSource> _watching = [];
    private readonly HashSet<string> _reachable = [];
    private readonly CancellationTokenSource _stop = new();
    private bool _started;
    private bool _disposed;

    public GuestService(HostStore hosts, ReceivedHistory history, SendSettings settings, string guestId, string guestName, string appVersion)
    {
        Hosts = hosts;
        _guestId = guestId;
        _guestName = guestName;
        _appVersion = appVersion;
        Connector = new HostConnector(hosts, guestId);
        Receiver = new HostReceiver(hosts, history, settings);
        hosts.Removed += (_, id) => StopWatching(id);
    }

    public HostStore Hosts { get; }
    public HostConnector Connector { get; }
    public HostReceiver Receiver { get; }

    /// <summary>A host became reachable or stopped being so; the arguments are its id and which.</summary>
    public event EventHandler<(string HostId, bool Reachable)>? ReachabilityChanged;

    /// <summary>A host that no longer knows this computer was dropped; the argument is its name.</summary>
    public event EventHandler<string>? Forgotten;

    public bool IsReachable(string hostId)
    {
        lock (_gate) return _reachable.Contains(hostId);
    }

    /// <summary>Starts taking what the paired hosts queue, and does so for each one paired later.</summary>
    public void Start()
    {
        lock (_gate) _started = true;
        foreach (var host in Hosts.Hosts) Watch(host.Id);
    }

    /// <summary>
    /// Pairs with the computer in a pairing link (scanned from its screen or pasted). The link carries the
    /// certificate's fingerprint, so the connection is pinned from the start; <paramref name="showMatch"/> gets the six digits
    /// the host shows too, before it asks its user, who answers within two minutes.
    /// </summary>
    public Task<GuestHost> PairWithLinkAsync(PairingUri link, Action<string> showMatch, CancellationToken cancellation) =>
        PairAsync(link.DesktopId, link.Name, link.Addresses, link.Port, link.FingerprintBytes, link.Token, fingerprint => SpkiFingerprint.CheckCode(fingerprint),
                  match =>
                  {
                      showMatch(match);
                      return Task.FromResult(true);
                  }, cancellation);

    /// <summary>
    /// Pairs with a computer found on the network by the code its screen shows. There is no fingerprint to check
    /// the certificate against yet, so it is trusted as first met. <paramref name="confirm"/> gets the six digits that agree
    /// with the host's screen only when the certificate is the host's own, and the code is not sent unless it answers yes.
    /// </summary>
    public Task<GuestHost> PairWithCodeAsync(NearbyHost host, string code, Func<string, Task<bool>> confirm, CancellationToken cancellation)
    {
        string canonical = PairingSession.NormalizeShortCode(code)
                           ?? throw new LinkException(403, ErrorCode.TokenInvalid, "A code is 8 letters and digits, like 7KQ2-M9XD.");
        return PairAsync(host.Id, host.Name, host.Addresses, host.Port, null, canonical, fingerprint => SpkiFingerprint.MatchCode(fingerprint, canonical),
                         confirm, cancellation);
    }

    private async Task<GuestHost> PairAsync(string hostId, string fallbackName, IReadOnlyList<string> addresses, int port, byte[]? pin, string token,
                                            Func<byte[], string> matchOf, Func<string, Task<bool>> confirm, CancellationToken cancellation)
    {
        string? reached = null;
        byte[]? fingerprint = pin;
        foreach (string address in HostStore.MergeAddresses(addresses, []))
        {
            using var probe = new LinkClient(address, port, pin, null);
            try
            {
                if ((await probe.HealthAsync(cancellation).ConfigureAwait(false)).Service != Protocol.ServiceName) continue;
            }
            catch (Exception e) when (e is IOException or LinkException)
            {
                continue;
            }
            reached = address;
            fingerprint = probe.Seen;
            break;
        }
        if (reached is null || fingerprint is null) throw new IOException("Could not reach that computer. Both need to be on the same network.");
        if (!await confirm(matchOf(fingerprint)).ConfigureAwait(false))
        {
            throw new LinkException(403, ErrorCode.Declined, "Cancelled: the digits did not match, so nothing was sent.");
        }

        // What was met first is the pin of the pairing itself, so the host that asks its user is the one whose digits were shown.
        using var client = new LinkClient(reached, port, fingerprint, null);
        var answer = await client.PairAsync(token, _guestId, PairedDeviceStore.CleanName(_guestName), "windows", _appVersion, cancellation).ConfigureAwait(false);
        if (Protocol.DecodeBase64Url(answer.DeviceSecret) is not { Length: PairedDeviceStore.SecretByteCount })
        {
            throw new LinkException(502, "badResponse", "The computer sent an answer this app could not use.");
        }
        if (answer.DesktopId != hostId)
        {
            await ForgetAtAsync(reached, port, fingerprint, answer.DeviceSecret).ConfigureAwait(false);
            throw new LinkException(502, "badResponse", "Another computer answered than the one chosen.");
        }
        string name = PairedDeviceStore.CleanName(answer.DesktopName);
        var host = new GuestHost
        {
            Id = answer.DesktopId,
            Name = name.Length > 0 ? name : fallbackName,
            Fingerprint = SpkiFingerprint.Text(fingerprint),
            Addresses = HostStore.MergeAddresses([reached], addresses),
            Port = port,
            LastAddress = reached,
            Paired = DateTimeOffset.UtcNow,
        };
        try
        {
            Hosts.Add(host, answer.DeviceSecret);
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            await ForgetAtAsync(reached, port, fingerprint, answer.DeviceSecret).ConfigureAwait(false);
            throw;
        }
        Watch(host.Id);
        return host;
    }

    /// <summary>The host counts this computer as paired when it is not kept here, so say otherwise there.</summary>
    private async Task ForgetAtAsync(string address, int port, byte[] fingerprint, string secret)
    {
        try
        {
            using var undo = new LinkClient(address, port, fingerprint, new Credentials(_guestId, secret));
            await undo.ForgetSelfAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or LinkException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not undo a pairing that was not kept: {e.Message}");
        }
    }

    public async Task SendTextAsync(string hostId, string text, CancellationToken cancellation)
    {
        using var sender = SenderFor(hostId);
        await sender.SendTextAsync(text, cancellation).ConfigureAwait(false);
    }

    public async Task SendLinkAsync(string hostId, string url, CancellationToken cancellation)
    {
        using var sender = SenderFor(hostId);
        await sender.SendLinkAsync(url, cancellation).ConfigureAwait(false);
    }

    public async Task SendFileAsync(string hostId, string path, IProgress<long>? progress, CancellationToken cancellation)
    {
        using var sender = SenderFor(hostId);
        await sender.SendFileAsync(path, progress, cancellation).ConfigureAwait(false);
    }

    private HostSender SenderFor(string hostId) => new(cancellation => Connector.ConnectAsync(hostId, cancellation));

    /// <summary>Tells the host to forget this computer (when it answers) and drops it here either way.</summary>
    public async Task ForgetAsync(string hostId)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var client = await Connector.ConnectAsync(hostId, timeout.Token).ConfigureAwait(false);
            await client.ForgetSelfAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or LinkException or OperationCanceledException)
        {
            // Out of reach: the host keeps its entry until its user removes it.
        }
        Hosts.Remove(hostId);
    }

    private void Watch(string hostId)
    {
        CancellationTokenSource watch;
        lock (_gate)
        {
            if (_disposed || !_started || _watching.ContainsKey(hostId)) return;
            watch = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
            _watching[hostId] = watch;
        }
        _ = Task.Run(() => WatchAsync(hostId, watch));
    }

    private void StopWatching(string hostId)
    {
        lock (_gate)
        {
            if (_watching.Remove(hostId, out var watch)) watch.Cancel();
            _reachable.Remove(hostId);
        }
    }

    /// <summary>Keeps taking what the host queues. Whatever goes wrong, it tries again later; only a removed host or the end of the app stops it.</summary>
    private async Task WatchAsync(string hostId, CancellationTokenSource watch)
    {
        var cancellation = watch.Token;
        var retry = FirstRetry;
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                try
                {
                    using var client = await Connector.ConnectAsync(hostId, cancellation).ConfigureAwait(false);
                    SetReachable(hostId, true);
                    retry = FirstRetry;
                    while (true) await Receiver.CollectAsync(client, hostId, Protocol.MaxOutboxWaitSeconds, cancellation).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
                {
                    return;
                }
                catch (LinkException e) when (e.Status == 401)
                {
                    string? name = Hosts.Find(hostId)?.Name;
                    SetReachable(hostId, false);
                    try
                    {
                        if (Hosts.Remove(hostId) && name is not null) Forgotten?.Invoke(this, name);
                        return;
                    }
                    catch (IOException)
                    {
                        // The entry could not be saved away; it stays and is asked again later.
                    }
                }
                catch (Exception)
                {
                    SetReachable(hostId, false);
                }
                try
                {
                    await Task.Delay(retry, cancellation).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                retry = TimeSpan.FromTicks(Math.Min(retry.Ticks * 2, LastRetry.Ticks));
            }
        }
        finally
        {
            lock (_gate)
            {
                if (_watching.TryGetValue(hostId, out var current) && ReferenceEquals(current, watch)) _watching.Remove(hostId);
                watch.Dispose();
            }
        }
    }

    private void SetReachable(string hostId, bool reachable)
    {
        lock (_gate)
        {
            if (!_watching.ContainsKey(hostId) || (reachable ? !_reachable.Add(hostId) : !_reachable.Remove(hostId))) return;
        }
        ReachabilityChanged?.Invoke(this, (hostId, reachable));
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            foreach (var watch in _watching.Values) watch.Cancel();
        }
        _stop.Cancel();
        _stop.Dispose();
    }
}
