using System.Net;
using LazySend.Core;

namespace LazySend.Core.Tests;

public class PairingTests
{
    [Fact]
    public async Task ApprovedPairingGivesTheSecretAndAuthenticatesTheNextCalls()
    {
        await using var h = new Harness();
        PairRequest? asked = null;
        h.Service.Router.ApprovePairing = (request, _, _) =>
        {
            asked = request;
            return Task.FromResult(true);
        };
        PairedDevice? paired = null;
        h.Service.Router.DevicePaired += (_, device) => paired = device;

        using var phone = await h.PairAsync("Aytu's iPhone");

        Assert.Equal("Aytu's iPhone", asked?.PhoneName);
        Assert.Equal(phone.Id, paired?.Id);
        Assert.Single(h.Service.Devices.Devices);
        Assert.NotEqual(phone.Secret, h.Service.Devices.Devices[0].SecretHash);
        using var hello = await phone.SendAsync(HttpMethod.Get, Protocol.HelloPath);
        Assert.Equal(HttpStatusCode.OK, hello.StatusCode);
        var body = await Harness.ReadAsync<HelloResponse>(hello);
        Assert.Equal("Test PC", body.DesktopName);
        Assert.Equal(Protocol.MaxChunkBytes, body.MaxChunkBytes);
    }

    [Fact]
    public async Task HelloListsTheComputersAddressesAsTheyAreNow()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Router.Addresses = () => ["192.168.1.5", "192.168.42.10"];

        using var hello = await phone.SendAsync(HttpMethod.Get, Protocol.HelloPath);

        Assert.Equal(["192.168.1.5", "192.168.42.10"], (await Harness.ReadAsync<HelloResponse>(hello)).Addresses);
    }

    [Fact]
    public async Task DeclinedPairingStoresNothing()
    {
        await using var h = new Harness();
        h.Service.Router.ApprovePairing = (_, _, _) => Task.FromResult(false);
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Equal(ErrorCode.Declined, await Harness.ErrorCodeAsync(response));
        Assert.Empty(h.Service.Devices.Devices);
        Assert.Equal(0, h.Service.Router.AwaitingApproval);
    }

    [Fact]
    public async Task NoAnswerWithinTheTimeoutDeclines()
    {
        await using var h = new Harness();
        h.Service.Router.ApprovalTimeout = TimeSpan.FromMilliseconds(200);
        h.Service.Router.ApprovePairing = async (_, _, cancellation) =>
        {
            await Task.Delay(TimeSpan.FromSeconds(30), cancellation);
            return true;
        };
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(ErrorCode.Declined, await Harness.ErrorCodeAsync(response));
    }

    [Fact]
    public async Task WrongTokenIsRefusedAndTheRightOneStillWorks()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var wrong = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(Protocol.EncodeBase64Url(new byte[16]), phone.Id, "Phone", "ios", "1")), authenticated: false);
        Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);
        Assert.Equal(ErrorCode.TokenInvalid, await Harness.ErrorCodeAsync(wrong));

        using var right = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, phone.Id, "Phone", "ios", "1")), authenticated: false);
        Assert.Equal(HttpStatusCode.OK, right.StatusCode);
    }

    [Theory]
    [InlineData(false, "")]
    [InlineData(true, " ")]
    public async Task ShortCodePairsAnyCaseWithOrWithoutTheDash(bool lower, string spaces)
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        string typed = h.Service.Pairing!.ShortCodeText;
        if (lower) typed = typed.ToLowerInvariant().Replace("-", spaces);
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(typed, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Single(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task ShortCodeAndTokenShareOneUse()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        string code = h.Service.Pairing!.ShortCodeText;
        using var first = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        using var second = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var one = await first.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(code, first.Id, "One", "windows", "1")), authenticated: false);
        using var two = await second.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, second.Id, "Two", "ios", "1")), authenticated: false);

        Assert.Equal(HttpStatusCode.OK, one.StatusCode);
        Assert.Equal(ErrorCode.PairingClosed, await Harness.ErrorCodeAsync(two));
        Assert.Single(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task WrongShortCodesCountAgainstThePeerLikeWrongTokens()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        string code = h.Service.Pairing!.ShortCodeText;
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        for (int i = 0; i < PairingSession.MaxFailedAttempts; i++)
        {
            using var wrong = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
                Harness.Json(new PairRequest("0000-0000", phone.Id, "Phone", "ios", "1")), authenticated: false);
            Assert.Equal(ErrorCode.TokenInvalid, await Harness.ErrorCodeAsync(wrong));
        }

        using var right = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(code, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(ErrorCode.PairingClosed, await Harness.ErrorCodeAsync(right));
        Assert.Empty(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task ApprovalGetsTheMatchCodeOfThePathUsed()
    {
        await using var h = new Harness();
        var matches = new List<string>();
        h.Service.Router.ApprovePairing = (_, match, _) =>
        {
            matches.Add(match);
            return Task.FromResult(true);
        };
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var scanner = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        (await scanner.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, scanner.Id, "Scanner", "ios", "1")), authenticated: false)).Dispose();
        h.Service.OpenPairing(["127.0.0.1"]);
        string code = h.Service.Pairing!.ShortCode;
        using var typer = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        (await typer.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(code, typer.Id, "Typer", "windows", "1")), authenticated: false)).Dispose();

        Assert.Equal(SpkiFingerprint.CheckCode(uri.FingerprintBytes!), matches[0]);
        Assert.Equal(SpkiFingerprint.MatchCode(uri.FingerprintBytes!, code), matches[1]);
        Assert.NotEqual(matches[0], matches[1]);
    }

    [Fact]
    public void ShortCodeIsEightCharactersWithoutAmbiguousLetters()
    {
        var session = new PairingSession(DateTimeOffset.UtcNow);

        Assert.Equal(8, session.ShortCode.Length);
        Assert.All(session.ShortCode, c => Assert.DoesNotContain(c, "ILOU"));
        Assert.Equal($"{session.ShortCode[..4]}-{session.ShortCode[4..]}", session.ShortCodeText);
        Assert.Equal(session.ShortCode, PairingSession.NormalizeShortCode(session.ShortCodeText.ToLowerInvariant()));
        Assert.Null(PairingSession.NormalizeShortCode("ABCD-EFG"));
        Assert.Null(PairingSession.NormalizeShortCode("ABCD-EFGI"));
        Assert.Null(PairingSession.NormalizeShortCode(session.Token));
    }

    [Fact]
    public async Task ExpiredTokenIsRefused()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        h.Now += PairingSession.Lifetime + TimeSpan.FromSeconds(1);

        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Equal(ErrorCode.PairingClosed, await Harness.ErrorCodeAsync(response));
        Assert.Empty(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task TokenWorksOnce()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var first = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());
        using var second = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var one = await first.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, first.Id, "One", "ios", "1")), authenticated: false);
        using var two = await second.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, second.Id, "Two", "ios", "1")), authenticated: false);

        Assert.Equal(HttpStatusCode.OK, one.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, two.StatusCode);
        Assert.Single(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task PairingNeedsAnOpenSession()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        h.Service.ClosePairing();
        using var phone = new Phone(h, uri.FingerprintBytes!, Protocol.NewId());

        using var response = await phone.SendAsync(HttpMethod.Post, Protocol.PairPath,
            Harness.Json(new PairRequest(uri.Token, phone.Id, "Phone", "ios", "1")), authenticated: false);

        Assert.Equal(ErrorCode.PairingClosed, await Harness.ErrorCodeAsync(response));
    }

    [Fact]
    public async Task OtherCertificateIsNotTrusted()
    {
        await using var h = new Harness();
        var uri = h.Service.OpenPairing(["127.0.0.1"]);
        using var phone = new Phone(h, new byte[SpkiFingerprint.ByteCount], Protocol.NewId());

        await Assert.ThrowsAsync<HttpRequestException>(() => phone.SendAsync(HttpMethod.Get, Protocol.HealthPath, authenticated: false));
    }

    [Fact]
    public async Task CallsNeedAPairedPhone()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        using var health = await phone.SendAsync(HttpMethod.Get, Protocol.HealthPath, authenticated: false);
        Assert.Equal(HttpStatusCode.OK, health.StatusCode);
        Assert.False((await Harness.ReadAsync<HealthResponse>(health)).Paired);

        phone.Secret = Protocol.EncodeBase64Url(new byte[32]);
        using var items = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: "hi"));
        Assert.Equal(HttpStatusCode.Unauthorized, items.StatusCode);
        using var outbox = await phone.SendAsync(HttpMethod.Get, Protocol.OutboxPath);
        Assert.Equal(HttpStatusCode.Unauthorized, outbox.StatusCode);
    }

    [Fact]
    public async Task RemovingSelfForgetsThePhoneAndWhatWaitsForIt()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Outbox.QueueText(phone.Id, "waiting");
        PairedDevice? removed = null;
        h.Service.Router.DeviceRemoved += (_, device) => removed = device;

        using var response = await phone.SendAsync(HttpMethod.Delete, Protocol.DeviceSelfPath);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal(phone.Id, removed?.Id);
        Assert.Empty(h.Service.Devices.Devices);
        Assert.Empty(h.Service.Outbox.Pending(phone.Id));
        using var after = await phone.SendAsync(HttpMethod.Get, Protocol.HelloPath);
        Assert.Equal(HttpStatusCode.Unauthorized, after.StatusCode);
    }

    [Fact]
    public async Task PairedPhoneSurvivesARestart()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        await h.RestartAsync();

        using var hello = await phone.SendAsync(HttpMethod.Get, Protocol.HelloPath);
        Assert.Equal(HttpStatusCode.OK, hello.StatusCode);
    }

    [Fact]
    public async Task TooManyFailuresBlockThePeer()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        string secret = phone.Secret;
        phone.Secret = Protocol.EncodeBase64Url(new byte[32]);
        for (int i = 0; i < LinkRateLimiter.MaxFailures; i++)
        {
            using var response = await phone.SendAsync(HttpMethod.Get, Protocol.HelloPath);
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }

        phone.Secret = secret;
        await Assert.ThrowsAnyAsync<HttpRequestException>(() => phone.SendAsync(HttpMethod.Get, Protocol.HelloPath));
    }
}
