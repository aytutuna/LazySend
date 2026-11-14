using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace LazySend.Core;

/// <summary>The id and secret this computer presents to a host it is paired with.</summary>
public sealed record Credentials(string DeviceId, string Secret);

/// <summary>A host's refusal: its status and error code, the sentence to show and, for <c>offsetMismatch</c>, where to continue.</summary>
public sealed class LinkException(int status, string code, string message, long? offset = null) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
    public long? Offset { get; } = offset;

    /// <summary>The host asks for a pause (rate limit) or is still finishing the previous request for the file.</summary>
    public bool IsBusy => Status == 429 || Code is ErrorCode.Busy or ErrorCode.RateLimited;
}

/// <summary>A file of the host's outbox being read; <see cref="Size"/> is the whole file's length, -1 when the host did not say.</summary>
public sealed class Download(HttpResponseMessage response, Stream body, int status, long size) : IDisposable
{
    public int Status { get; } = status;
    public long Size { get; } = size;
    public Stream Body { get; } = body;

    public void Dispose()
    {
        Body.Dispose();
        response.Dispose();
    }
}

/// <summary>
/// One host at one address, over TLS pinned to its key (the other side of <see cref="LinkRouter"/>, as the phones
/// use it). Every call is a connection of its own, as the host closes after each answer. A client made
/// without a pin trusts what it meets and keeps its fingerprint in <see cref="Seen"/>; it is only for the first
/// contact of a pairing by short code, and the fingerprint it saw becomes the pin of every client after it.
/// Network failures surface as <see cref="IOException"/>, refusals as <see cref="LinkException"/>.
/// </summary>
public sealed class LinkClient : IDisposable
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan PairTimeout = TimeSpan.FromSeconds(130);
    private static readonly TimeSpan ChunkTimeout = TimeSpan.FromMinutes(5);

    private readonly HttpClient _http;
    private readonly string _host;
    private readonly int _port;
    private readonly byte[]? _pin;
    private readonly Credentials? _credentials;

    public LinkClient(string host, int port, byte[]? pin, Credentials? credentials)
    {
        _host = host;
        _port = port;
        _pin = pin;
        _credentials = credentials;
        _http = new HttpClient(new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(5),
            UseProxy = false,
            SslOptions = new SslClientAuthenticationOptions { RemoteCertificateValidationCallback = (_, certificate, _, _) => Validate(certificate) },
        })
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public string Host => _host;

    /// <summary>The fingerprint of the certificate the last connection met.</summary>
    public byte[]? Seen { get; private set; }

    private bool Validate(X509Certificate? certificate)
    {
        if (certificate is null) return false;
        using var leaf = X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
        byte[] fingerprint = SpkiFingerprint.Of(leaf);
        Seen = fingerprint;
        return _pin is null || SpkiFingerprint.Matches(fingerprint, _pin);
    }

    public Task<HealthResponse> HealthAsync(CancellationToken cancellation = default) =>
        JsonAsync<HealthResponse>(Request(HttpMethod.Get, Protocol.HealthPath, authenticated: false), RequestTimeout, cancellation);

    /// <summary>Waits for the person at the host: it answers once they approve, or declines after 120 seconds.</summary>
    public Task<PairResponse> PairAsync(string token, string guestId, string guestName, string platform, string appVersion,
                                        CancellationToken cancellation = default)
    {
        var request = Request(HttpMethod.Post, Protocol.PairPath, authenticated: false);
        request.Content = JsonContent(new PairRequest(token, guestId, guestName, platform, appVersion));
        return JsonAsync<PairResponse>(request, PairTimeout, cancellation);
    }

    public Task<HelloResponse> HelloAsync(CancellationToken cancellation = default) =>
        JsonAsync<HelloResponse>(Request(HttpMethod.Get, Protocol.HelloPath), TimeSpan.FromSeconds(4), cancellation);

    public async Task ForgetSelfAsync(CancellationToken cancellation = default)
    {
        using var response = await SendAsync(Request(HttpMethod.Delete, Protocol.DeviceSelfPath), RequestTimeout, cancellation).ConfigureAwait(false);
        await EnsureSuccessAsync(response).ConfigureAwait(false);
    }

    public Task<ItemState> PostItemAsync(ItemRequest item, CancellationToken cancellation = default)
    {
        var request = Request(HttpMethod.Post, Protocol.ItemsPath);
        request.Content = JsonContent(item);
        return JsonAsync<ItemState>(request, RequestTimeout, cancellation);
    }

    public Task<ItemState> ItemStateAsync(string id, CancellationToken cancellation = default) =>
        JsonAsync<ItemState>(Request(HttpMethod.Get, Protocol.ItemsPrefix + id), RequestTimeout, cancellation);

    /// <summary>Sends <paramref name="data"/> as the file's bytes from <paramref name="offset"/>; the host answers where the file stands.</summary>
    public Task<ItemState> PutChunkAsync(string id, long offset, ReadOnlyMemory<byte> data, CancellationToken cancellation = default)
    {
        var request = Request(HttpMethod.Put, $"{Protocol.ItemsPrefix}{id}/data");
        // Asks the host to say yes or no before the bytes go, so a refusal is not lost to a reset.
        request.Headers.ExpectContinue = true;
        request.Headers.TryAddWithoutValidation(Protocol.OffsetHeader, offset.ToString(CultureInfo.InvariantCulture));
        request.Content = new ReadOnlyMemoryContent(data);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return JsonAsync<ItemState>(request, ChunkTimeout, cancellation);
    }

    /// <summary>What waits for this computer; with nothing pending the host holds the request open up to <paramref name="waitSeconds"/>.</summary>
    public Task<OutboxResponse> OutboxAsync(int waitSeconds, CancellationToken cancellation = default)
    {
        int wait = Math.Clamp(waitSeconds, 0, Protocol.MaxOutboxWaitSeconds);
        return JsonAsync<OutboxResponse>(Request(HttpMethod.Get, $"{Protocol.OutboxPath}?wait={wait}"),
                                         TimeSpan.FromSeconds(wait + 15), cancellation);
    }

    /// <summary>Opens the file of an outbox item from <paramref name="from"/>; the caller disposes it.</summary>
    public async Task<Download> DownloadAsync(string id, long from, CancellationToken cancellation = default)
    {
        var request = Request(HttpMethod.Get, $"{Protocol.OutboxPrefix}{id}/data");
        if (from > 0) request.Headers.Range = new RangeHeaderValue(from, null);
        var response = await SendAsync(request, RequestTimeout, cancellation, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        try
        {
            await EnsureSuccessAsync(response).ConfigureAwait(false);
            long length = response.Content.Headers.ContentLength ?? -1;
            int status = (int)response.StatusCode;
            long size = length < 0 ? -1 : status == 206 ? from + length : length;
            var body = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
            return new Download(response, body, status, size);
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }

    public async Task AcknowledgeAsync(string id, CancellationToken cancellation = default)
    {
        using var response = await SendAsync(Request(HttpMethod.Delete, Protocol.OutboxPrefix + id), RequestTimeout, cancellation).ConfigureAwait(false);
        await EnsureSuccessAsync(response).ConfigureAwait(false);
    }

    public void Dispose() => _http.Dispose();

    private HttpRequestMessage Request(HttpMethod method, string pathAndQuery, bool authenticated = true)
    {
        string host = _host.Contains(':') ? $"[{_host}]" : _host;
        var request = new HttpRequestMessage(method, $"https://{host}:{_port}{pathAndQuery}")
        {
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
        if (authenticated && _credentials is not null)
        {
            request.Headers.Add(Protocol.DeviceIdHeader, _credentials.DeviceId);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _credentials.Secret);
        }
        return request;
    }

    private static StringContent JsonContent<T>(T value) => new(Protocol.ToJson(value), System.Text.Encoding.UTF8, "application/json");

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, TimeSpan timeout, CancellationToken cancellation,
                                                      HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        limit.CancelAfter(timeout);
        try
        {
            return await _http.SendAsync(request, completion, limit.Token).ConfigureAwait(false);
        }
        catch (HttpRequestException e)
        {
            throw new IOException(e.Message, e);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new IOException("The computer did not answer in time.");
        }
    }

    private async Task<T> JsonAsync<T>(HttpRequestMessage request, TimeSpan timeout, CancellationToken cancellation) where T : class
    {
        using var response = await SendAsync(request, timeout, cancellation).ConfigureAwait(false);
        await EnsureSuccessAsync(response).ConfigureAwait(false);
        byte[] body;
        try
        {
            body = await response.Content.ReadAsByteArrayAsync(cancellation).ConfigureAwait(false);
        }
        catch (HttpRequestException e)
        {
            throw new IOException(e.Message, e);
        }
        return Protocol.FromJson<T>(body)
               ?? throw new LinkException((int)response.StatusCode, "badResponse", "The computer sent an answer this app could not read.");
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;
        LinkError? error = null;
        try
        {
            error = Protocol.FromJson<LinkError>(await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false));
        }
        catch (Exception e) when (e is IOException or HttpRequestException)
        {
            // The status is all there is.
        }
        int status = (int)response.StatusCode;
        throw new LinkException(status, error?.Error is { Length: > 0 } code ? code : $"http{status}",
                                error?.Message is { Length: > 0 } message ? message : $"The computer answered {status}.", error?.Offset);
    }
}
