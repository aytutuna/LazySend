using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using LazySend.Core;

namespace LazySend.Core.Tests;

/// <summary>The real server on loopback with a temporary folder for everything it keeps.</summary>
public sealed class Harness : IAsyncDisposable
{
    private static readonly Lazy<X509Certificate2> TestCertificate = new(() => SelfSignedCertificate.Create("test"));

    private readonly Func<string, long> _freeSpace;
    public readonly string Root = Path.Combine(Path.GetTempPath(), "lazysend-tests-" + Guid.NewGuid().ToString("N"));
    public DateTimeOffset Now = new(2026, 11, 11, 12, 0, 0, TimeSpan.Zero);
    public long FreeBytes = long.MaxValue;

    public Harness()
    {
        _freeSpace = _ => FreeBytes;
        Paths = new SendPaths(Path.Combine(Root, "settings"), Path.Combine(Root, "state"), Path.Combine(Root, "received"));
        Service = Create();
    }

    public SendPaths Paths { get; }
    public LinkService Service { get; private set; }
    public int Port { get; private set; }
    public X509Certificate2 Certificate => TestCertificate.Value;
    public string ReceivedRoot => Paths.DefaultReceiveRoot;

    private LinkService Create()
    {
        var service = new LinkService(Paths, Certificate, new LinkServerOptions(), () => Now, _freeSpace);
        service.Router.DesktopName = () => "Test PC";
        service.Router.ApprovePairing = (_, _, _) => Task.FromResult(true);
        Port = service.Start(0, IPAddress.Loopback);
        return service;
    }

    /// <summary>Stops the server and starts a new one on the same folders, as a restart of the app would.</summary>
    public async Task RestartAsync()
    {
        await Service.DisposeAsync();
        Service = Create();
    }

    public async Task<Phone> PairAsync(string name = "Test iPhone", string? id = null)
    {
        var uri = Service.OpenPairing(["127.0.0.1"]);
        var phone = new Phone(this, uri.FingerprintBytes!, id ?? Protocol.NewId());
        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Json(new PairRequest(uri.Token, phone.Id, name, "ios", "1.0")), authenticated: false);
        response.EnsureSuccessStatusCode();
        phone.Secret = (await ReadAsync<PairResponse>(response)).DeviceSecret;
        return phone;
    }

    public static StringContent Json<T>(T value) => new(Protocol.ToJson(value), Encoding.UTF8, "application/json");

    public static async Task<T> ReadAsync<T>(HttpResponseMessage response) =>
        JsonSerializer.Deserialize<T>(await response.Content.ReadAsByteArrayAsync(), Protocol.Json)!;

    public static async Task<string> ErrorCodeAsync(HttpResponseMessage response) => (await ReadAsync<LinkError>(response)).Error;

    public async ValueTask DisposeAsync()
    {
        await Service.DisposeAsync();
        try
        {
            Directory.Delete(Root, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

/// <summary>A phone: it connects to the desktop and pins the certificate by the fingerprint from the pairing code.</summary>
public sealed class Phone : IDisposable
{
    private readonly Harness _harness;
    private readonly HttpClient _http;

    public Phone(Harness harness, byte[] pin, string id)
    {
        _harness = harness;
        Pin = pin;
        Id = id;
        _http = new HttpClient(new SocketsHttpHandler
        {
            SslOptions = new SslClientAuthenticationOptions
            {
                RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                    certificate is not null && SpkiFingerprint.Matches(SpkiFingerprint.Of(new X509Certificate2(certificate)), pin),
            },
        });
    }

    public byte[] Pin { get; }
    public string Id { get; }
    public string Secret { get; set; } = "";

    public Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content = null, bool authenticated = true,
                                               params (string Name, string Value)[] headers)
    {
        var request = new HttpRequestMessage(method, $"https://127.0.0.1:{_harness.Port}{path}") { Content = content };
        if (authenticated)
        {
            request.Headers.Add(Protocol.DeviceIdHeader, Id);
            request.Headers.Authorization = new("Bearer", Secret);
        }
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        return _http.SendAsync(request);
    }

    public Task<HttpResponseMessage> PostAsync<T>(string path, T body) => SendAsync(HttpMethod.Post, path, Harness.Json(body));

    public Task<HttpResponseMessage> PutChunkAsync(string id, long offset, byte[] data) =>
        SendAsync(HttpMethod.Put, $"{Protocol.ItemsPrefix}{id}/data", new ByteArrayContent(data), true, (Protocol.OffsetHeader, offset.ToString()));

    /// <summary>Starts a file and returns its state.</summary>
    public async Task<ItemState> BeginFileAsync(string name, byte[] content, string? sourceId = null, DateTimeOffset? modified = null,
                                                bool withHash = true)
    {
        var request = new ItemRequest(ItemKind.File, Name: name, Size: content.Length, Modified: modified, SourceId: sourceId,
                                      Sha256: withHash ? Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(content)) : null);
        using var response = await PostAsync(Protocol.ItemsPath, request);
        response.EnsureSuccessStatusCode();
        return await Harness.ReadAsync<ItemState>(response);
    }

    public async Task<ItemState> GetStateAsync(string id)
    {
        using var response = await SendAsync(HttpMethod.Get, Protocol.ItemsPrefix + id);
        response.EnsureSuccessStatusCode();
        return await Harness.ReadAsync<ItemState>(response);
    }

    /// <summary>Sends the head of a chunk and only <paramref name="sent"/> of its bytes, then hangs up, as a phone does when the Wi-Fi drops.</summary>
    public async Task DropMidChunkAsync(string id, long offset, long declared, byte[] sent)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, _harness.Port);
        await using var tls = new SslStream(tcp.GetStream(), false, (_, certificate, _, _) =>
            SpkiFingerprint.Matches(SpkiFingerprint.Of(new X509Certificate2(certificate!)), Pin));
        await tls.AuthenticateAsClientAsync("127.0.0.1");
        string head = $"PUT {Protocol.ItemsPrefix}{id}/data HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Device-Id: {Id}\r\nAuthorization: Bearer {Secret}\r\n"
                      + $"X-Offset: {offset}\r\nContent-Length: {declared}\r\n\r\n";
        await tls.WriteAsync(Encoding.ASCII.GetBytes(head));
        await tls.WriteAsync(sent);
        await tls.FlushAsync();
    }

    public void Dispose() => _http.Dispose();
}
