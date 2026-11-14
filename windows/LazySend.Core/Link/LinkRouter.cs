using System.Globalization;
using System.Text;

namespace LazySend.Core;

/// <summary>
/// What the phone link server does with each request (the routes are in CONTRACTS.md). Unpaired
/// clients may only check reachability and pair with the open pairing session's token; everything
/// else needs a paired phone's id and secret, and a wrong secret gets 401. Every request counts
/// towards the sender's rate limit, every failed secret or token towards its failure limit. Events
/// are raised on the request's thread.
/// </summary>
public sealed class LinkRouter
{
    private readonly PairedDeviceStore _devices;
    private readonly Inbox _inbox;
    private readonly ReceivedHistory _history;
    private readonly Outbox _outbox;
    private readonly GalleryIndex _gallery;
    private readonly LinkRateLimiter _limiter;
    private readonly Func<DateTimeOffset> _clock;
    private int _awaitingApproval;

    public LinkRouter(PairedDeviceStore devices, Inbox inbox, ReceivedHistory history, Outbox outbox, GalleryIndex gallery,
                      LinkRateLimiter limiter, Func<DateTimeOffset>? clock = null)
    {
        _devices = devices;
        _inbox = inbox;
        _history = history;
        _outbox = outbox;
        _gallery = gallery;
        _limiter = limiter;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public Func<string> DesktopName { get; set; } = () => Environment.MachineName;

    /// <summary>The computer's addresses now, for hello, so a phone paired on one network finds it on another (a USB tether).</summary>
    public Func<IReadOnlyList<string>> Addresses { get; set; } = () => LocalNetworks.PairingAddresses();

    /// <summary>The pairing session open now; null when pairing is not open.</summary>
    public Func<PairingSession?> CurrentPairing { get; set; } = () => null;

    /// <summary>The certificate's fingerprint now, for the match code of a pairing by short code.</summary>
    public Func<byte[]> Fingerprint { get; set; } = () => [];

    /// <summary>
    /// Asks the user whether the phone that presented a valid token may pair, with the six digits both
    /// screens should show. Without an answer within <see cref="ApprovalTimeout"/> the pairing is
    /// declined. The default declines too: a code is only shown where someone can answer.
    /// </summary>
    public Func<PairRequest, string, CancellationToken, Task<bool>> ApprovePairing { get; set; } = (_, _, _) => Task.FromResult(false);

    public TimeSpan ApprovalTimeout { get; set; } = TimeSpan.FromSeconds(120);

    public event EventHandler<PairedDevice>? DevicePaired;
    public event EventHandler<PairedDevice>? DeviceRemoved;
    public event EventHandler<ReceivedItem>? TextReceived;

    /// <summary>Phones that presented a valid token and wait for the user's answer, so the desktop keeps listening for them.</summary>
    public int AwaitingApproval => Volatile.Read(ref _awaitingApproval);

    /// <summary>A pairing request counted in <see cref="AwaitingApproval"/> ended: paired, declined, refused or cut off.</summary>
    public event EventHandler? ApprovalSettled;

    public async Task<LinkResponse> HandleAsync(LinkRequest request, CancellationToken cancellation)
    {
        var now = _clock();
        if (!_limiter.TryRequest(request.Remote, now))
        {
            return LinkResponse.Error(429, LinkError.RateLimited, Header("Retry-After", "60"));
        }
        var head = request.Head;
        string path = head.Path;
        switch (path)
        {
            case Protocol.HealthPath:
                return head.Method == "GET" ? Health(request, now) : NotAllowed("GET");
            case Protocol.PairPath:
                return head.Method == "POST" ? await PairAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("POST");
            case Protocol.HelloPath:
                return head.Method == "GET" ? Hello(request, now) : NotAllowed("GET");
            case Protocol.DeviceSelfPath:
                return head.Method == "DELETE" ? RemoveSelf(request, now) : NotAllowed("DELETE");
            case Protocol.ItemsPath:
                return head.Method == "POST" ? await PostItemAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("POST");
            case Protocol.GalleryCheckPath:
                return head.Method == "POST" ? await GalleryCheckAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("POST");
            case Protocol.OutboxPath:
                return head.Method == "GET" ? await OutboxAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("GET");
        }
        if (path.StartsWith(Protocol.ItemsPrefix, StringComparison.Ordinal))
        {
            string rest = path[Protocol.ItemsPrefix.Length..];
            if (rest.EndsWith("/data", StringComparison.Ordinal))
            {
                return head.Method == "PUT"
                    ? await PutChunkAsync(request, rest[..^5], now, cancellation).ConfigureAwait(false)
                    : NotAllowed("PUT");
            }
            return head.Method == "GET" ? ItemStatus(request, rest, now) : NotAllowed("GET");
        }
        if (path.StartsWith(Protocol.OutboxPrefix, StringComparison.Ordinal))
        {
            string rest = path[Protocol.OutboxPrefix.Length..];
            if (rest.EndsWith("/data", StringComparison.Ordinal))
            {
                return head.Method == "GET" ? OutboxData(request, rest[..^5], now) : NotAllowed("GET");
            }
            return head.Method == "DELETE" ? Acknowledge(request, rest, now) : NotAllowed("DELETE");
        }
        return LinkResponse.Error(404, LinkError.NotFound);
    }

    private static KeyValuePair<string, string> Header(string name, string value) => new(name, value);

    private static LinkResponse NotAllowed(string allow) =>
        LinkResponse.Error(405, LinkError.MethodNotAllowed, Header("Allow", allow));

    private static LinkResponse Unauthorized() =>
        LinkResponse.Error(401, LinkError.Unauthorized, Header("WWW-Authenticate", "Bearer"));

    /// <summary>The paired phone the request comes from; null (a failure counted) when its id and secret do not match one.</summary>
    private PairedDevice? Authenticate(LinkRequest request, DateTimeOffset now)
    {
        var device = _devices.Authenticate(request.Head.Header(Protocol.DeviceIdHeader), request.Head.BearerToken, now);
        if (device is null) _limiter.RecordFailure(request.Remote, now);
        return device;
    }

    private LinkResponse Health(LinkRequest request, DateTimeOffset now)
    {
        bool paired = false;
        if (request.Head.BearerToken is not null || request.Head.Header(Protocol.DeviceIdHeader) is not null)
        {
            if (Authenticate(request, now) is null) return Unauthorized();
            paired = true;
        }
        return LinkResponse.Json(200, new HealthResponse(Protocol.ServiceName, Protocol.Version, paired));
    }

    private LinkResponse Hello(LinkRequest request, DateTimeOffset now)
    {
        if (Authenticate(request, now) is null) return Unauthorized();
        return LinkResponse.Json(200, new HelloResponse(Protocol.Version, _devices.DesktopId, DesktopName(), Protocol.MaxChunkBytes, Addresses()));
    }

    private async Task<LinkResponse> PairAsync(LinkRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (request.Head.ContentLength is not { } length) return LinkResponse.Error(411, LinkError.LengthRequired);
        if (length > Protocol.MaxSmallBodyBytes) return LinkResponse.Error(413, LinkError.TooLarge);
        // Before the body is read: a body is only worth waiting for while a code is shown.
        if (CurrentPairing() is not { } session) return LinkResponse.Error(403, LinkError.PairingClosed);
        if (await ReadBodyAsync(request.Body, length, cancellation).ConfigureAwait(false) is not { } body
            || Protocol.FromJson<PairRequest>(body) is not { } pair || !Protocol.IsValidId(pair.PhoneId))
        {
            return LinkResponse.Error(400, LinkError.BadRequest);
        }
        // Counted from before the token is used until the phone is stored (or refused), so the desktop
        // never stops listening in between.
        Interlocked.Increment(ref _awaitingApproval);
        bool settleWhenWritten = false;
        try
        {
            switch (session.Redeem(pair.Token, now, request.Remote))
            {
                case PairingRedeemResult.WrongToken:
                    _limiter.RecordFailure(request.Remote, now);
                    return LinkResponse.Error(403, LinkError.TokenInvalid);
                case PairingRedeemResult.Expired:
                    return LinkResponse.Error(403, LinkError.TokenExpired);
                case PairingRedeemResult.AlreadyUsed:
                    return LinkResponse.Error(403, LinkError.TokenUsed);
                case PairingRedeemResult.Closed:
                    return LinkResponse.Error(403, LinkError.PairingClosed);
            }
            string name = PairedDeviceStore.CleanName(pair.PhoneName);
            pair = pair with { PhoneName = name.Length > 0 ? name : "Phone" };
            byte[] fingerprint = Fingerprint();
            string match = PairingSession.NormalizeShortCode(pair.Token) is { } code
                ? SpkiFingerprint.MatchCode(fingerprint, code)
                : SpkiFingerprint.CheckCode(fingerprint);
            var response = await ApproveAndPairAsync(pair, match, cancellation).ConfigureAwait(false);
            settleWhenWritten = response.Written is not null;
            return response;
        }
        finally
        {
            if (!settleWhenWritten) SettleApproval();
        }
    }

    private void SettleApproval()
    {
        Interlocked.Decrement(ref _awaitingApproval);
        ApprovalSettled?.Invoke(this, EventArgs.Empty);
    }

    private async Task<LinkResponse> ApproveAndPairAsync(PairRequest pair, string match, CancellationToken cancellation)
    {
        bool approved;
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
        {
            timeout.CancelAfter(ApprovalTimeout);
            try
            {
                approved = await ApprovePairing(pair, match, timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                approved = false;
            }
        }
        if (!approved) return LinkResponse.Error(403, LinkError.Declined);
        string secret;
        try
        {
            secret = _devices.Pair(pair.PhoneId, pair.PhoneName, pair.Platform, pair.AppVersion, _clock());
        }
        catch (InvalidOperationException)
        {
            return LinkResponse.Error(409, LinkError.TooManyDevices);
        }
        catch (IOException)
        {
            return LinkResponse.Error(500, LinkError.ServerError);
        }
        var response = LinkResponse.Json(200, new PairResponse(Protocol.Version, _devices.DesktopId, DesktopName(), secret));
        // The phone counts as paired once it has the secret; when the reply never got to it, it is forgotten again.
        response.Written = delivered =>
        {
            try
            {
                if (!delivered) _devices.Remove(pair.PhoneId);
                else if (_devices.Devices.FirstOrDefault(d => d.Id == pair.PhoneId) is { } device) DevicePaired?.Invoke(this, device);
            }
            finally
            {
                SettleApproval();
            }
        };
        return response;
    }

    private LinkResponse RemoveSelf(LinkRequest request, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        _devices.Remove(device.Id);
        DeviceRemoved?.Invoke(this, device);
        return LinkResponse.Empty(204);
    }

    private async Task<LinkResponse> PostItemAsync(LinkRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (request.Head.ContentLength is not { } length) return LinkResponse.Error(411, LinkError.LengthRequired);
        if (length > Protocol.MaxItemBodyBytes) return LinkResponse.Error(413, LinkError.TooLarge);
        if (await ReadBodyAsync(request.Body, length, cancellation).ConfigureAwait(false) is not { } body
            || Protocol.FromJson<ItemRequest>(body) is not { } item)
        {
            return LinkResponse.Error(400, LinkError.BadRequest);
        }
        switch (item.Kind)
        {
            case ItemKind.Text:
                if (string.IsNullOrEmpty(item.Text)) return LinkResponse.Error(400, LinkError.BadRequest);
                if (Encoding.UTF8.GetByteCount(item.Text) > Protocol.MaxTextBytes) return LinkResponse.Error(413, LinkError.TooLarge);
                return Stored(_history.Add(device, ItemKind.Text, item.Text, null, now));
            case ItemKind.Link:
                if (!ReceivedLinks.IsAcceptable(item.Url)) return LinkResponse.Error(400, LinkError.BadRequest);
                return Stored(_history.Add(device, ItemKind.Link, null, item.Url, now));
            case ItemKind.File:
                try
                {
                    var state = _inbox.Begin(device, item);
                    return LinkResponse.Json(state.Done ? 200 : 201, state);
                }
                catch (InboxException e)
                {
                    return LinkResponse.Error(e.Status, e.Error);
                }
            default:
                return LinkResponse.Error(400, LinkError.BadRequest);
        }

        LinkResponse Stored(ReceivedItem stored)
        {
            TextReceived?.Invoke(this, stored);
            return LinkResponse.Json(201, new ItemState(stored.Id, 0, true));
        }
    }

    private LinkResponse ItemStatus(LinkRequest request, string id, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (!Protocol.IsValidId(id) || _inbox.State(device.Id, id) is not { } state) return LinkResponse.Error(404, LinkError.NotFound);
        return LinkResponse.Json(200, state);
    }

    private async Task<LinkResponse> PutChunkAsync(LinkRequest request, string id, DateTimeOffset now, CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (!Protocol.IsValidId(id)) return LinkResponse.Error(404, LinkError.NotFound);
        if (request.Head.ContentLength is not { } length) return LinkResponse.Error(411, LinkError.LengthRequired);
        if (length > Protocol.MaxChunkBytes) return LinkResponse.Error(413, LinkError.TooLarge);
        string? offsetText = request.Head.Header(Protocol.OffsetHeader);
        if (offsetText is null || offsetText.Length > 15 || !offsetText.All(char.IsAsciiDigit)
            || !long.TryParse(offsetText, NumberStyles.None, CultureInfo.InvariantCulture, out long offset))
        {
            return LinkResponse.Error(400, LinkError.BadRequest);
        }
        try
        {
            var state = await _inbox.WriteAsync(device.Id, id, offset, length, request.Body, cancellation).ConfigureAwait(false);
            return LinkResponse.Json(200, state);
        }
        catch (InboxException e)
        {
            return LinkResponse.Error(e.Status, e.Error);
        }
    }

    private async Task<LinkResponse> GalleryCheckAsync(LinkRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (request.Head.ContentLength is not { } length) return LinkResponse.Error(411, LinkError.LengthRequired);
        if (length > Protocol.MaxGalleryCheckBodyBytes) return LinkResponse.Error(413, LinkError.TooLarge);
        if (await ReadBodyAsync(request.Body, length, cancellation).ConfigureAwait(false) is not { } body
            || Protocol.FromJson<GalleryCheckRequest>(body) is not { Ids: { } ids } || ids.Any(id => !GalleryIndex.IsValidSourceId(id)))
        {
            return LinkResponse.Error(400, LinkError.BadRequest);
        }
        if (ids.Count > Protocol.MaxGalleryCheckIds) return LinkResponse.Error(413, LinkError.TooLarge);
        return LinkResponse.Json(200, new GalleryCheckResponse(_gallery.Missing(device.Id, ids)));
    }

    private async Task<LinkResponse> OutboxAsync(LinkRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        int wait = 0;
        if (LinkHttp.QueryParameters(request.Head.Query).TryGetValue("wait", out string? text)
            && (text.Length is 0 or > 6 || !int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out wait)))
        {
            return LinkResponse.Error(400, LinkError.BadRequest);
        }
        wait = Math.Min(wait, Protocol.MaxOutboxWaitSeconds);
        var items = await _outbox.WaitAsync(device.Id, TimeSpan.FromSeconds(wait), cancellation).ConfigureAwait(false);
        // TODO: a phone that hangs up during the wait is only noticed when the wait ends.
        var entries = new List<OutboxEntry>();
        long inline = 0;
        foreach (var item in items)
        {
            long bytes = Encoding.UTF8.GetByteCount(item.Text ?? "") + Encoding.UTF8.GetByteCount(item.Url ?? "");
            if (entries.Count > 0 && (entries.Count >= Protocol.MaxOutboxItemsPerReply || inline + bytes > Protocol.MaxOutboxInlineBytes)) break;
            entries.Add(item.ToEntry());
            inline += bytes;
        }
        return LinkResponse.Json(200, new OutboxResponse(entries, entries.Count < items.Count ? true : null));
    }

    private LinkResponse OutboxData(LinkRequest request, string id, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (_outbox.Find(device.Id, id) is not { Kind: ItemKind.File, Path: { } path } item) return LinkResponse.Error(404, LinkError.NotFound);
        long start = 0;
        string? range = request.Head.Header("Range");
        bool partial = range is not null;
        if (range is not null)
        {
            // Only "bytes=n-" is understood: a download resumed where it broke.
            if (!range.StartsWith("bytes=", StringComparison.Ordinal) || !range.EndsWith('-') || range.Length is < 8 or > 22
                || !long.TryParse(range.AsSpan(6, range.Length - 7), NumberStyles.None, CultureInfo.InvariantCulture, out start))
            {
                return LinkResponse.Error(416, LinkError.RangeNotSatisfiable);
            }
        }
        FileStream stream;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.Asynchronous | FileOptions.SequentialScan);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return LinkResponse.Error(404, LinkError.NotFound);
        }
        long size = stream.Length;
        if (size == 0) partial = false;
        if (item.Size is { } queued && queued != size)
        {
            stream.Dispose();
            return LinkResponse.Error(409, LinkError.Changed);
        }
        if (start > size || (partial && start == size && size > 0))
        {
            stream.Dispose();
            return LinkResponse.Error(416, LinkError.RangeNotSatisfiable, Header("Content-Range", $"bytes */{size}"));
        }
        stream.Seek(start, SeekOrigin.Begin);
        var type = Header("Content-Type", item.Mime ?? "application/octet-stream");
        var accept = Header("Accept-Ranges", "bytes");
        if (!partial) return LinkResponse.FromStream(200, stream, size, type, accept);
        return LinkResponse.FromStream(206, stream, size - start, type, accept,
                                       Header("Content-Range", $"bytes {start}-{size - 1}/{size}"));
    }

    private LinkResponse Acknowledge(LinkRequest request, string id, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        _outbox.Acknowledge(device.Id, id);
        return LinkResponse.Empty(204);
    }

    /// <summary>The whole body (small ones only); null when it ended early.</summary>
    private static async Task<byte[]?> ReadBodyAsync(LinkRequestBody body, long length, CancellationToken cancellation)
    {
        var bytes = new byte[length];
        int filled = 0;
        while (filled < length)
        {
            int read = await body.ReadAsync(bytes.AsMemory(filled), cancellation).ConfigureAwait(false);
            if (read == 0) return null;
            filled += read;
        }
        return bytes;
    }
}
