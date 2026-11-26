using System.Security.Cryptography;
using System.Text.Json;
using uniffi.lazy_link_ffi;

namespace LazySend.RustLink.Tests;

public class RustLinkTests
{
    private static JsonElement Load(string file)
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "testdata", "link", file))) dir = Path.GetDirectoryName(dir);
        if (dir is null) throw new FileNotFoundException(file);
        return JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dir, "testdata", "link", file))).RootElement;
    }

    private static byte[] Bytes(JsonElement e) => e.EnumerateArray().Select(b => (byte)b.GetInt32()).ToArray();

    private static byte[] FromBase64Url(string text) =>
        Convert.FromBase64String(text.Replace('-', '+').Replace('_', '/').PadRight((text.Length + 3) / 4 * 4, '='));

    [Fact]
    public void PairingCodesAreReadAsTheDataSays()
    {
        foreach (var c in Load("pairing-uris.json").GetProperty("cases").EnumerateArray())
        {
            string name = c.GetProperty("name").GetString()!;
            string result = c.GetProperty("result").GetString()!;
            string uri = c.GetProperty("uri").GetString()!;
            if (result != "ok")
            {
                var error = Assert.ThrowsAny<LinkException>(() => LazyLinkFfiMethods.ParsePairingCode(uri));
                Assert.True(string.Equals(error.GetType().Name, result, StringComparison.OrdinalIgnoreCase), $"{name}: {error.GetType().Name}");
                continue;
            }
            var code = LazyLinkFfiMethods.ParsePairingCode(uri);
            var want = c.GetProperty("pairing");
            Assert.Equal(want.GetProperty("desktopId").GetString(), code.DesktopId);
            Assert.Equal(want.GetProperty("name").GetString(), code.Name);
            Assert.Equal(want.GetProperty("fingerprint").GetString(), code.Fingerprint);
            Assert.Equal(want.GetProperty("port").GetInt32(), code.Port);
            Assert.Equal(want.GetProperty("token").GetString(), code.Token);
            Assert.Equal(want.GetProperty("addresses").EnumerateArray().Select(a => a.GetString()!), code.Addresses);
            Assert.Equal(want.GetProperty("checkCode").GetString(), LazyLinkFfiMethods.CheckCode(FromBase64Url(code.Fingerprint)));
            string written = LazyLinkFfiMethods.FormatPairingCode(code);
            Assert.Equal(written, LazyLinkFfiMethods.FormatPairingCode(LazyLinkFfiMethods.ParsePairingCode(written)));
        }
    }

    [Fact]
    public void CheckCodesMatch()
    {
        foreach (var c in Load("check-codes.json").GetProperty("cases").EnumerateArray())
        {
            byte[] fingerprint = Bytes(c.GetProperty("fingerprint"));
            Assert.Equal(c.GetProperty("checkCode").GetString(), LazyLinkFfiMethods.CheckCode(fingerprint));
            Assert.Equal(c.GetProperty("matchCode").GetString(), LazyLinkFfiMethods.MatchCode(fingerprint, c.GetProperty("shortCode").GetString()!));
        }
    }

    [Fact]
    public void ShortCodesAreReadAndRedeemedAsTheDataSays()
    {
        var data = Load("short-codes.json");
        foreach (var n in data.GetProperty("normalize").EnumerateArray())
        {
            if (n.GetProperty("typed").ValueKind == JsonValueKind.Null) continue;
            string typed = n.GetProperty("typed").GetString()!;
            string? expected = n.GetProperty("canonical").GetString();
            Assert.Equal(expected, LazyLinkFfiMethods.NormalizeShortCode(typed));
        }
        byte[] token = Bytes(data.GetProperty("tokenBytes"));
        foreach (var r in data.GetProperty("redeem").EnumerateArray())
        {
            using var session = new PairingSession(0, token, [7, 3, 21, 0, 9, 31, 12, 5]);
            string typedCode = session.ShortCode()[..4].ToLowerInvariant() + "-" + session.ShortCode()[4..].ToLowerInvariant();
            foreach (var a in r.GetProperty("attempts").EnumerateArray())
            {
                string? presented = a.GetProperty("token").ValueKind == JsonValueKind.Null ? null : a.GetProperty("token").GetString() switch
                {
                    "$token" => session.Token(),
                    "$shortCode" => session.ShortCode(),
                    "$shortCodeTyped" => typedCode,
                    var other => other,
                };
                var got = session.Redeem(presented, a.GetProperty("at").GetInt64() * 1000, a.GetProperty("peer").GetString());
                Assert.True(string.Equals(got.ToString(), a.GetProperty("expect").GetString(), StringComparison.OrdinalIgnoreCase),
                            $"{r.GetProperty("name").GetString()}: expected {a.GetProperty("expect").GetString()}, got {got}");
            }
        }
    }

    // The key stays in these classes: Rust only sees the hash going out and the signature coming back.
    private sealed class EcdsaSigner(ECDsa key) : Signer
    {
        public byte[] Sign(byte[] hash) => key.SignHash(hash);
    }

    private sealed class SlowSigner(ECDsa key) : AsyncSigner
    {
        public async Task<byte[]> Sign(byte[] hash)
        {
            await Task.Delay(20);
            return key.SignHash(hash);
        }
    }

    private sealed class RefusingSigner : Signer
    {
        public byte[] Sign(byte[] hash) => throw new InvalidOperationException("the key is locked");
    }

    [Fact]
    public void RustHandsTheHashToTheNativeSigner()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        byte[] data = [1, 2, 3, 4, 5];
        byte[] signature = LazyLinkFfiMethods.SignData(new EcdsaSigner(key), data);
        Assert.True(key.VerifyData(data, signature, HashAlgorithmName.SHA256));
    }

    [Fact]
    public void ANativeSignerThatThrowsComesBackAsAnError()
    {
        Assert.ThrowsAny<LinkException>(() => LazyLinkFfiMethods.SignData(new RefusingSigner(), [1]));
    }

    [Fact]
    public async Task AsyncSigningRoundTrips()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        byte[] data = [9, 8, 7];
        byte[] signature = await LazyLinkFfiMethods.SignDataAsync(new SlowSigner(key), data);
        Assert.True(key.VerifyData(data, signature, HashAlgorithmName.SHA256));
    }

    [Fact]
    public void ARustPanicIsAnException()
    {
        var error = Assert.ThrowsAny<UniffiException>(() => LazyLinkFfiMethods.PanicNow("boom"));
        Assert.Contains("boom", error.Message);
        // The library keeps working afterwards.
        Assert.Equal("", LazyLinkFfiMethods.CheckCode([1]));
    }

    [Fact]
    public void FiftyMegabytesCrossBothWays()
    {
        const int size = 50 * 1024 * 1024;
        var data = new byte[size];
        for (int i = 0; i < size; i++) data[i] = (byte)(i % 251);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(data)), LazyLinkFfiMethods.HashBytes(data));
        var back = LazyLinkFfiMethods.PatternBytes(size);
        Assert.Equal(size, back.Length);
        Assert.True(back.AsSpan().SequenceEqual(data));
    }
}
