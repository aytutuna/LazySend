using System.Net;
using System.Text;
using LazySend.Core;

namespace LazySend.Core.Tests;

public class PairingUriTests
{
    private static PairingUri Sample(IReadOnlyList<string>? addresses = null) => new(
        Convert.ToHexStringLower(new byte[16]), "Aytu's PC", Protocol.EncodeBase64Url(new byte[32]),
        addresses ?? ["192.168.1.5", "172.20.10.2", "fd00::1"], 52734, Protocol.EncodeBase64Url(new byte[16]));

    [Fact]
    public void FormatsAndParsesBack()
    {
        var uri = Sample();
        string text = uri.Format();

        Assert.StartsWith("lazysend://pair?v=1&id=", text);
        Assert.Equal(uri, PairingUri.Parse(text));
    }

    [Fact]
    public void ForeignCodesAreRefused()
    {
        var other = Assert.Throws<PairingUriException>(() => PairingUri.Parse("lazyprint://pair?v=1"));
        var web = Assert.Throws<PairingUriException>(() => PairingUri.Parse("https://alazy.app"));
        var newer = Assert.Throws<PairingUriException>(() => PairingUri.Parse(Sample().Format().Replace("v=1", "v=2")));
        var damaged = Assert.Throws<PairingUriException>(() => PairingUri.Parse("lazysend://pair?v=1&id=short"));

        Assert.Equal(PairingUriErrorKind.NotPairingCode, other.Kind);
        Assert.Equal(PairingUriErrorKind.NotPairingCode, web.Kind);
        Assert.Equal(PairingUriErrorKind.NewerVersion, newer.Kind);
        Assert.Equal(PairingUriErrorKind.Damaged, damaged.Kind);
    }

    [Fact]
    public void UnknownParametersAreIgnored()
    {
        Assert.Equal(Sample(), PairingUri.Parse(Sample().Format() + "&x=1"));
    }

    [Fact]
    public void FormatRefusesWhatParseWould()
    {
        Assert.Throws<ArgumentException>(() => Sample(["not an address"]).Format());
        Assert.Throws<ArgumentException>(() => Sample([.. Enumerable.Repeat("10.0.0.1", 9)]).Format());
    }
}

public class PairingSessionTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 11, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void TokenIsSixteenBytesAndWorksOnce()
    {
        var session = new PairingSession(T0);

        Assert.Equal(16, Protocol.DecodeBase64Url(session.Token)!.Length);
        Assert.Equal(PairingRedeemResult.Accepted, session.Redeem(session.Token, T0.AddMinutes(1)));
        Assert.Equal(PairingRedeemResult.AlreadyUsed, session.Redeem(session.Token, T0.AddMinutes(1)));
    }

    [Fact]
    public void TokenExpiresAfterFiveMinutes()
    {
        var session = new PairingSession(T0);

        Assert.Equal(PairingRedeemResult.Accepted, new PairingSession(T0, new byte[16]).Redeem(Protocol.EncodeBase64Url(new byte[16]), T0.AddMinutes(4.9)));
        Assert.Equal(PairingRedeemResult.Expired, session.Redeem(session.Token, T0.AddMinutes(5)));
        Assert.Equal(PairingSessionState.Expired, session.StateAt(T0.AddMinutes(5)));
    }

    [Fact]
    public void FivePeerFailuresRefuseThatPeerOnly()
    {
        var session = new PairingSession(T0);
        var peer = IPAddress.Parse("10.0.0.2");
        for (int i = 0; i < PairingSession.MaxFailedAttempts; i++)
        {
            Assert.Equal(PairingRedeemResult.WrongToken, session.Redeem("bad", T0, peer));
        }

        Assert.Equal(PairingRedeemResult.Closed, session.Redeem(session.Token, T0, peer));
        Assert.Equal(PairingRedeemResult.Accepted, session.Redeem(session.Token, T0, IPAddress.Parse("10.0.0.3")));
    }
}

public class ProtocolTests
{
    [Fact]
    public void Base64UrlRoundTripsAndRefusesOddText()
    {
        byte[] data = [0xFB, 0xFF, 0x01, 0x02];

        Assert.Equal(data, Protocol.DecodeBase64Url(Protocol.EncodeBase64Url(data)));
        Assert.Null(Protocol.DecodeBase64Url("+/+/"));
        Assert.Null(Protocol.DecodeBase64Url("AA=="));
        Assert.Null(Protocol.DecodeBase64Url("A"));
        Assert.Null(Protocol.DecodeBase64Url("AB"));
    }

    [Fact]
    public void IdsAreFileNameSafe()
    {
        Assert.True(Protocol.IsValidId(Protocol.NewId()));
        Assert.False(Protocol.IsValidId("short"));
        Assert.False(Protocol.IsValidId("../../etc/passwd"));
        Assert.False(Protocol.IsValidId(new string('a', 65)));
    }
}

public class MatchCodeTests
{
    // The Swift server's tests hold the same vector.
    private static readonly byte[] Fingerprint = [.. Enumerable.Range(0, 32).Select(i => (byte)i)];

    [Fact]
    public void CheckCodeIsTheFirstFourBytesModAMillion()
    {
        Assert.Equal("066051", SpkiFingerprint.CheckCode(Fingerprint));
        Assert.Equal("066 051", SpkiFingerprint.Spaced("066051"));
    }

    [Fact]
    public void MatchCodeIsTakenFromTheHashOfTheFingerprintAndTheCode()
    {
        Assert.Equal("987292", SpkiFingerprint.MatchCode(Fingerprint, "7KQ2M9XD"));
        Assert.Equal("987 292", SpkiFingerprint.Spaced(SpkiFingerprint.MatchCode(Fingerprint, "7KQ2M9XD")));
    }
}

public class TxtRecordTests
{
    [Fact]
    public void RecordCarriesVersionIdAndName()
    {
        var txt = Protocol.TxtRecords("abcdef0123456789", "Aytu's PC");

        Assert.Equal(["v=1", "id=abcdef0123456789", "n=Aytu's PC"], txt.Select(e => $"{e.Key}={e.Value}"));
    }

    [Fact]
    public void LongNameIsCutOnACharacterBoundary()
    {
        var txt = Protocol.TxtRecords("abcdef0123456789", new string('a', 60) + "ééé");

        string name = txt.Single(e => e.Key == Protocol.TxtNameKey).Value;
        Assert.Equal(new string('a', 60) + "éé", name);
        Assert.True(Encoding.UTF8.GetByteCount(name) <= Protocol.MaxTxtNameBytes);
    }

    [Fact]
    public void EmptyNameLeavesTheKeyOut()
    {
        Assert.DoesNotContain(Protocol.TxtRecords("abcdef0123456789", " 	 ").Select(e => e.Key), key => key == Protocol.TxtNameKey);
    }
}

public class HttpTests
{
    private static HttpParseResult Parse(string head) => LinkHttp.Parse(Encoding.Latin1.GetBytes(head));

    [Fact]
    public void ChunkedRequestsAreRefused()
    {
        var result = Parse("PUT /v1/items/x/data HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n");

        Assert.Equal(HttpParseStatus.Invalid, result.Status);
        Assert.Equal(501, result.ErrorStatus);
    }

    [Fact]
    public void ReadsRangeAndOffsetHeaders()
    {
        var result = Parse("GET /v1/outbox/x/data HTTP/1.1\r\nHost: a\r\nRange: bytes=5-\r\nAuthorization: Bearer abc\r\n\r\n");

        Assert.Equal(HttpParseStatus.Complete, result.Status);
        Assert.Equal("bytes=5-", result.Head!.Header("range"));
        Assert.Equal("abc", result.Head.BearerToken);
    }

    [Fact]
    public void MalformedHeadsAreRefused()
    {
        Assert.Equal(400, Parse("GET / HTTP/1.1\r\n\r\n").ErrorStatus);
        Assert.Equal(400, Parse("GET / HTTP/1.1\nHost: a\n\n").ErrorStatus);
        Assert.Equal(400, Parse("PUT / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n").ErrorStatus);
        Assert.Equal(505, Parse("GET / HTTP/2.0\r\nHost: a\r\n\r\n").ErrorStatus);
    }
}

public class StorageTests
{
    [Theory]
    [InlineData("holiday.jpg", "holiday.jpg")]
    [InlineData("a/b\\c.txt", "a_b_c.txt")]
    [InlineData("what?.txt", "what_.txt")]
    [InlineData("NUL.txt", "_NUL.txt")]
    [InlineData("com1", "_com1")]
    [InlineData("name. ", "name")]
    [InlineData("", "file")]
    [InlineData("...", "file")]
    [InlineData(".gitignore", ".gitignore")]
    public void NamesAreMadeSafe(string input, string expected) => Assert.Equal(expected, FileNames.Clean(input));

    [Fact]
    public void LongNamesAreCutAndKeepTheirExtension()
    {
        string cleaned = FileNames.Clean(new string('ü', 300) + ".jpeg");

        Assert.True(Encoding.UTF8.GetByteCount(cleaned) <= FileNames.MaxBytes);
        Assert.EndsWith(".jpeg", cleaned);
    }

    [Fact]
    public void UniqueAddsNumbers()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazysend-names-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            Assert.Equal("a.txt", FileNames.Unique(folder, "a.txt"));
            File.WriteAllText(Path.Combine(folder, "a.txt"), "");
            Assert.Equal("a (2).txt", FileNames.Unique(folder, "a.txt"));
            File.WriteAllText(Path.Combine(folder, "a (2).txt"), "");
            Assert.Equal("a (3).txt", FileNames.Unique(folder, "a.txt"));
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void GalleryIndexHoldsTensOfThousandsAndReloads()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazysend-index-" + Guid.NewGuid().ToString("N"));
        try
        {
            var index = new GalleryIndex(folder);
            var ids = Enumerable.Range(0, 30_000).Select(i => $"ph://{i:D8}/L0/001").ToList();
            foreach (string id in ids.Take(20_000)) index.Add("phone-one", id);

            var reloaded = new GalleryIndex(folder);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var missing = reloaded.Missing("phone-one", ids);

            Assert.Equal(10_000, missing.Count);
            Assert.Equal(ids[20_000], missing[0]);
            Assert.True(watch.Elapsed < TimeSpan.FromSeconds(2));
            Assert.Equal(30_000, reloaded.Missing("phone-two", ids).Count);
            reloaded.Clear("phone-one");
            Assert.Equal(30_000, new GalleryIndex(folder).Missing("phone-one", ids).Count);
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void HistoryKeepsNewestFirstAndIsCapped()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazysend-history-" + Guid.NewGuid().ToString("N"));
        try
        {
            var history = new ReceivedHistory(Path.Combine(folder, "history.json"));
            var device = new PairedDevice { Id = "device-one", Name = "Phone" };
            for (int i = 0; i < ReceivedHistory.MaxItems + 20; i++) history.Add(device, ItemKind.Text, $"note {i}", null, DateTimeOffset.UtcNow);

            Assert.Equal(ReceivedHistory.MaxItems, history.Items.Count);
            Assert.Equal($"note {ReceivedHistory.MaxItems + 19}", history.Items[0].Text);
            Assert.Equal(ReceivedHistory.MaxItems, new ReceivedHistory(Path.Combine(folder, "history.json")).Items.Count);
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void HistoryDropsOldTextWhenItAddsUpToTooMuch()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazysend-history-" + Guid.NewGuid().ToString("N"));
        try
        {
            var history = new ReceivedHistory(Path.Combine(folder, "history.json"));
            var device = new PairedDevice { Id = "device-one", Name = "Phone" };
            string big = new('x', 1024 * 1024);
            for (int i = 0; i < 20; i++) history.Add(device, ItemKind.Text, big, null, DateTimeOffset.UtcNow);

            Assert.InRange(history.Items.Count, 1, 16);
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }
}

public class NetworkTests
{
    [Fact]
    public void UsbNetworkAddressesStayInThePairingCode()
    {
        var subnets = new[]
        {
            new LocalSubnet(IPAddress.Parse("192.168.1.20"), 24),
            new LocalSubnet(IPAddress.Parse("172.20.10.3"), 28),
            new LocalSubnet(IPAddress.Parse("192.168.42.129"), 24),
            new LocalSubnet(IPAddress.Parse("169.254.10.1"), 16),
            new LocalSubnet(IPAddress.Parse("fd12::5"), 64),
        };

        var addresses = LocalNetworks.PairingAddresses(subnets);

        Assert.Equal(["192.168.1.20", "172.20.10.3", "192.168.42.129", "169.254.10.1", "fd12::5"], addresses);
        Assert.True(addresses.All(PairingUri.IsValidAddress));
    }

    [Fact]
    public void PairingCodeHoldsAtMostEightAddresses()
    {
        var subnets = Enumerable.Range(1, 12).Select(i => new LocalSubnet(IPAddress.Parse($"10.0.{i}.1"), 24));

        Assert.Equal(PairingUri.MaxAddresses, LocalNetworks.PairingAddresses(subnets).Count);
    }

    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("10.1.2.3", true)]
    [InlineData("172.20.10.2", true)]
    [InlineData("192.168.42.129", true)]
    [InlineData("100.64.1.1", false)]
    [InlineData("fe80::1", true)]
    [InlineData("fd00::1", true)]
    [InlineData("::ffff:192.168.1.5", true)]
    [InlineData("8.8.8.8", false)]
    [InlineData("172.32.0.1", false)]
    [InlineData("2001:4860::1", false)]
    public void PrivateAddressesAreLocal(string address, bool local) => Assert.Equal(local, LocalNetworks.IsLocalAddress(IPAddress.Parse(address)));

    [Fact]
    public async Task ServerAnswersOnTheAnyAddress()
    {
        await using var h = new Harness();
        await using var any = new LinkServer(h.Certificate, h.Service.Router, new LinkRateLimiter());

        int port = any.Start(0);

        Assert.True(port > 0);
        Assert.True(any.IsRunning);
    }

    [Fact]
    public void CertificateIsPinnedByItsKey()
    {
        using var certificate = SelfSignedCertificate.Create("PC");
        var fingerprint = SpkiFingerprint.Of(certificate);

        Assert.Equal(SpkiFingerprint.ByteCount, fingerprint.Length);
        Assert.Equal(43, SpkiFingerprint.Text(fingerprint).Length);
        Assert.Equal(6, SpkiFingerprint.CheckCode(fingerprint).Length);
        Assert.True(certificate.HasPrivateKey);
    }
}

public class SharedAddressTests
{
    [Fact]
    public void SharedAddressSpaceIsAllowedOnlyInsideAnOwnSubnet()
    {
        var peer = IPAddress.Parse("100.64.1.1");

        Assert.False(LocalNetworks.IsLocalAddress(peer));
        Assert.True(new LocalSubnet(IPAddress.Parse("100.64.1.9"), 10).Contains(peer));
        Assert.False(new LocalSubnet(IPAddress.Parse("192.168.1.9"), 24).Contains(peer));
    }
}

public class FirewallTests
{
    private const string App = @"C:\Apps\LazySend.exe";

    private static FirewallRule Rule(bool allow, string ports = "*", string path = App, FirewallProfiles profiles = FirewallProfiles.All, int protocol = Firewall.ProtocolTcp) =>
        new("Lazy Send", path, true, allow, true, profiles, protocol, ports);

    [Fact]
    public void VerdictFollowsTheRules()
    {
        Assert.Equal(FirewallVerdict.Off, Firewall.Evaluate([], App, FirewallProfiles.Private, false, 52734));
        Assert.Equal(FirewallVerdict.WillAsk, Firewall.Evaluate([], App, FirewallProfiles.Private, true, 52734));
        Assert.Equal(FirewallVerdict.Allowed, Firewall.Evaluate([Rule(true)], App, FirewallProfiles.Private, true, 52734));
        Assert.Equal(FirewallVerdict.Blocked, Firewall.Evaluate([Rule(true), Rule(false)], App, FirewallProfiles.Private, true, 52734));
        Assert.Equal(FirewallVerdict.WillAsk, Firewall.Evaluate([Rule(true, path: @"C:\Other.exe")], App, FirewallProfiles.Private, true, 52734));
        Assert.Equal(FirewallVerdict.WillAsk, Firewall.Evaluate([Rule(true, profiles: FirewallProfiles.Public)], App, FirewallProfiles.Private, true, 52734));
        Assert.Equal(FirewallVerdict.WillAsk, Firewall.Evaluate([Rule(true, protocol: 17)], App, FirewallProfiles.Private, true, 52734));
    }

    [Theory]
    [InlineData("*", true)]
    [InlineData("", true)]
    [InlineData("52734", true)]
    [InlineData("80,52700-52800", true)]
    [InlineData("80,443", false)]
    public void PortsAreMatchedInListsAndRanges(string ports, bool expected) => Assert.Equal(expected, Firewall.PortMatches(ports, 52734));
}

public class PairingCodeTests
{
    [Fact]
    public async Task CodeKeepsItsTokenWhenAddressesChange()
    {
        await using var h = new Harness();
        var first = h.Service.OpenPairing(["192.168.1.5"]);

        var later = h.Service.PairingCode(["192.168.1.5", "172.20.10.2"]);

        Assert.Equal(first.Token, later!.Token);
        Assert.Equal(["192.168.1.5", "172.20.10.2"], later.Addresses);
        h.Service.ClosePairing();
        Assert.Null(h.Service.PairingCode());
    }
}

public class CertificateReplacementTests
{
    [Fact]
    public async Task ReplacedCertificateServesNewConnections()
    {
        await using var h = new Harness();
        using var first = await h.PairAsync();
        using var renewed = SelfSignedCertificate.Create("renewed");

        h.Service.ReplaceCertificate(renewed);

        Assert.Equal(SpkiFingerprint.Of(renewed), h.Service.Fingerprint);
        using var pinnedToNew = new Phone(h, SpkiFingerprint.Of(renewed), first.Id) { Secret = first.Secret };
        using var response = await pinnedToNew.SendAsync(HttpMethod.Get, Protocol.HelloPath);
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
        await Assert.ThrowsAsync<HttpRequestException>(() => first.SendAsync(HttpMethod.Get, Protocol.HelloPath));
    }
}
