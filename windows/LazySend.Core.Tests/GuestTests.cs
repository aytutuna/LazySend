using System.Security.Cryptography;
using LazySend.Core;

namespace LazySend.Core.Tests;

/// <summary>This computer as a guest, with the real server of <see cref="Harness"/> as the host.</summary>
public sealed class GuestRig : IDisposable
{
    public GuestRig(Harness host)
    {
        Host = host;
        Paths = new SendPaths(Path.Combine(host.Root, "guest-settings"), Path.Combine(host.Root, "guest-state"), Path.Combine(host.Root, "guest-received"));
        Hosts = new HostStore(Path.Combine(Paths.Settings, "hosts.json"));
        History = new ReceivedHistory(Paths.HistoryFile);
        GuestId = Protocol.NewId();
        Service = new GuestService(Hosts, History, new SendSettings(Paths), GuestId, "Guest PC", "1.0");
    }

    public Harness Host { get; }
    public SendPaths Paths { get; }
    public HostStore Hosts { get; }
    public ReceivedHistory History { get; }
    public string GuestId { get; }
    public GuestService Service { get; }

    public NearbyHost Nearby => new(Host.Service.Devices.DesktopId, "Test PC", ["127.0.0.1"], Host.Port);

    /// <summary>Pairs by the host's short code and returns the host entry.</summary>
    public async Task<GuestHost> PairAsync()
    {
        Host.Service.OpenPairing(["127.0.0.1"]);
        return await Service.PairWithCodeAsync(Nearby, Host.Service.Pairing!.ShortCodeText, _ => { }, CancellationToken.None);
    }

    public void Dispose() => Service.Dispose();
}

public class GuestPairingTests
{
    [Fact]
    public async Task PairingByCodePinsTheKeyItMetAndBothScreensShowTheSameDigits()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        string? hostSaw = null;
        string? guestSaw = null;
        h.Service.Router.ApprovePairing = (_, match, _) =>
        {
            hostSaw = match;
            return Task.FromResult(true);
        };
        h.Service.OpenPairing(["127.0.0.1"]);
        string code = h.Service.Pairing!.ShortCode;

        var host = await guest.Service.PairWithCodeAsync(guest.Nearby, code.ToLowerInvariant(), match => guestSaw = match, CancellationToken.None);

        Assert.Equal(SpkiFingerprint.MatchCode(h.Service.Fingerprint, code), guestSaw);
        Assert.Equal(guestSaw, hostSaw);
        Assert.Equal(h.Service.Devices.DesktopId, host.Id);
        Assert.Equal("Test PC", host.Name);
        Assert.Equal(SpkiFingerprint.Text(h.Service.Fingerprint), host.Fingerprint);
        Assert.NotNull(guest.Hosts.Secret(host.Id));
        var paired = Assert.Single(h.Service.Devices.Devices);
        Assert.Equal(guest.GuestId, paired.Id);
        Assert.Equal("windows", paired.Platform);
        Assert.Equal("Guest PC", paired.Name);
    }

    [Fact]
    public async Task PairingByLinkShowsTheCheckCodeAndPinsFromTheStart()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        string? hostSaw = null;
        string? guestSaw = null;
        h.Service.Router.ApprovePairing = (_, match, _) =>
        {
            hostSaw = match;
            return Task.FromResult(true);
        };
        var link = PairingUri.Parse(h.Service.OpenPairing(["127.0.0.1"]).Format());

        await guest.Service.PairWithLinkAsync(link, match => guestSaw = match, CancellationToken.None);

        Assert.Equal(SpkiFingerprint.CheckCode(h.Service.Fingerprint), guestSaw);
        Assert.Equal(guestSaw, hostSaw);
    }

    [Fact]
    public async Task LinkWithAnotherKeyIsNotTrusted()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var real = h.Service.OpenPairing(["127.0.0.1"]);
        var forged = real with { Fingerprint = SpkiFingerprint.Text(new byte[SpkiFingerprint.ByteCount]) };

        await Assert.ThrowsAsync<IOException>(() => guest.Service.PairWithLinkAsync(forged, _ => { }, CancellationToken.None));

        Assert.Empty(guest.Hosts.Hosts);
        Assert.Empty(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task WrongCodeIsRefusedAndTheRightOneStillWorks()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        h.Service.OpenPairing(["127.0.0.1"]);

        var refused = await Assert.ThrowsAsync<LinkException>(() => guest.Service.PairWithCodeAsync(guest.Nearby, "0000-0000", _ => { }, CancellationToken.None));
        var malformed = await Assert.ThrowsAsync<LinkException>(() => guest.Service.PairWithCodeAsync(guest.Nearby, "nope", _ => { }, CancellationToken.None));
        await guest.Service.PairWithCodeAsync(guest.Nearby, h.Service.Pairing!.ShortCodeText, _ => { }, CancellationToken.None);

        Assert.Equal(ErrorCode.TokenInvalid, refused.Code);
        Assert.Equal(ErrorCode.TokenInvalid, malformed.Code);
        Assert.Single(guest.Hosts.Hosts);
    }

    [Fact]
    public async Task DeclinedPairingKeepsNothing()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        h.Service.Router.ApprovePairing = (_, _, _) => Task.FromResult(false);
        h.Service.OpenPairing(["127.0.0.1"]);

        var refused = await Assert.ThrowsAsync<LinkException>(() => guest.Service.PairWithCodeAsync(guest.Nearby, h.Service.Pairing!.ShortCode, _ => { }, CancellationToken.None));

        Assert.Equal(ErrorCode.Declined, refused.Code);
        Assert.Empty(guest.Hosts.Hosts);
    }

    [Fact]
    public async Task AnotherComputerAnsweringIsRefused()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        h.Service.OpenPairing(["127.0.0.1"]);
        var other = guest.Nearby with { Id = Protocol.NewId() };

        await Assert.ThrowsAsync<LinkException>(() => guest.Service.PairWithCodeAsync(other, h.Service.Pairing!.ShortCode, _ => { }, CancellationToken.None));

        Assert.Empty(guest.Hosts.Hosts);
    }
}

public class GuestConnectionTests
{
    [Fact]
    public async Task HelloRefreshesTheAddressesAndTheLastOneThatWorked()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        h.Service.Router.Addresses = () => ["192.0.2.7", "127.0.0.1"];
        guest.Hosts.Update(host.Id, entry => entry.Addresses = ["192.0.2.99", "127.0.0.1"]);

        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        var stored = guest.Hosts.Find(host.Id)!;
        Assert.Equal("127.0.0.1", stored.LastAddress);
        Assert.Equal(["192.0.2.7", "127.0.0.1", "192.0.2.99"], stored.Addresses);
    }

    [Fact]
    public async Task AnnouncedAddressesAreTriedWhenTheKnownOnesFail()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        guest.Hosts.Update(host.Id, entry =>
        {
            entry.Addresses = [];
            entry.LastAddress = null;
        });
        guest.Service.Connector.Announced = (_, _) => Task.FromResult<IReadOnlyList<string>>(["127.0.0.1"]);

        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        Assert.Equal("127.0.0.1", guest.Hosts.Find(host.Id)!.LastAddress);
    }

    [Fact]
    public async Task HostThatForgotTheGuestAnswersUnauthorized()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        h.Service.Devices.Remove(guest.GuestId);

        var refused = await Assert.ThrowsAsync<LinkException>(() => guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None));

        Assert.Equal(401, refused.Status);
    }

    [Fact]
    public async Task UnreachableHostIsAnIOException()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        guest.Hosts.Update(host.Id, entry =>
        {
            entry.Addresses = ["127.0.0.1"];
            entry.Port = 1;
        });

        await Assert.ThrowsAsync<IOException>(() => guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None));
    }

    [Fact]
    public async Task ForgettingTellsTheHostAndDropsTheEntry()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();

        await guest.Service.ForgetAsync(host.Id);

        Assert.Empty(guest.Hosts.Hosts);
        Assert.Empty(h.Service.Devices.Devices);
    }

    [Fact]
    public async Task RunningServiceReceivesWhatTheHostQueuesAndDropsAHostThatForgotIt()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        var arrived = new TaskCompletionSource<ReceivedItem>(TaskCreationOptions.RunContinuationsAsynchronously);
        var forgotten = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        guest.Service.Receiver.TextReceived += (_, item) => arrived.TrySetResult(item);
        guest.Service.Forgotten += (_, name) => forgotten.TrySetResult(name);
        guest.Service.Start();

        h.Service.Outbox.QueueText(guest.GuestId, "from the host");

        var item = await arrived.Task.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Equal("from the host", item.Text);
        h.Service.Devices.Remove(guest.GuestId);
        Assert.Equal("Test PC", await forgotten.Task.WaitAsync(TimeSpan.FromSeconds(40)));
        Assert.Empty(guest.Hosts.Hosts);
    }
}

public class GuestSendTests
{
    [Fact]
    public async Task TextAndLinkLandInTheHostsHistory()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();

        await guest.Service.SendTextAsync(host.Id, "hello there", CancellationToken.None);
        await guest.Service.SendLinkAsync(host.Id, "https://alazy.app/send/", CancellationToken.None);

        var items = h.Service.History.Items;
        Assert.Equal(["https://alazy.app/send/", "hello there"], items.Select(i => i.Url ?? i.Text));
        Assert.All(items, i => Assert.Equal("Guest PC", i.DeviceName));
    }

    [Fact]
    public async Task FileGoesUpInChunksAndLandsWithItsHash()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string path = Path.Combine(h.Root, "big.bin");
        byte[] content = RandomNumberGenerator.GetBytes(HostSender.ChunkBytes * 2 + 12345);
        await File.WriteAllBytesAsync(path, content);
        var progress = new List<long>();

        await guest.Service.SendFileAsync(host.Id, path, new SyncProgress(progress), CancellationToken.None);

        string received = Path.Combine(h.ReceivedRoot, "Guest PC", "big.bin");
        Assert.Equal(content, await File.ReadAllBytesAsync(received));
        Assert.Equal(content.Length, progress.Max());
    }

    [Fact]
    public async Task DroppedUploadContinuesFromTheOffsetTheHostGives()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string path = Path.Combine(h.Root, "cut.bin");
        byte[] content = RandomNumberGenerator.GetBytes(HostSender.ChunkBytes + 70_000);
        await File.WriteAllBytesAsync(path, content);
        var request = HostSender.FileRequest(path) with { SourceId = "cut-1" };
        // A first try that sent 100000 bytes and dropped in the middle of the next chunk.
        using var earlier = new Phone(h, h.Service.Fingerprint, guest.GuestId) { Secret = guest.Hosts.Secret(host.Id)! };
        using var begun = await earlier.PostAsync(Protocol.ItemsPath, request);
        Assert.Equal(System.Net.HttpStatusCode.Created, begun.StatusCode);
        var state = await Harness.ReadAsync<ItemState>(begun);
        using (var first = await earlier.PutChunkAsync(state.Id, 0, content[..100_000])) first.EnsureSuccessStatusCode();
        await earlier.DropMidChunkAsync(state.Id, 100_000, 200_000, content[100_000..150_000]);
        long held = await SettledOffsetAsync(earlier, state.Id);
        Assert.InRange(held, 100_000, 150_000);
        var progress = new List<long>();
        using var sender = new HostSender(token => guest.Service.Connector.ConnectAsync(host.Id, token), []);

        await sender.SendFileAsync(request, path, new SyncProgress(progress), CancellationToken.None);

        string[] files = Directory.GetFiles(Path.Combine(h.ReceivedRoot, "Guest PC", "Gallery"), "cut.bin", SearchOption.AllDirectories);
        Assert.Equal(content, await File.ReadAllBytesAsync(Assert.Single(files)));
        Assert.Equal(held, progress.First());
    }

    [Fact]
    public async Task SameSourceTwiceIsAnnouncedAsADuplicateAndNotSentAgain()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string path = Path.Combine(h.Root, "once.txt");
        await File.WriteAllTextAsync(path, "once");
        var request = HostSender.FileRequest(path) with { SourceId = "once-1" };
        using var sender = new HostSender(token => guest.Service.Connector.ConnectAsync(host.Id, token), []);
        await sender.SendFileAsync(request, path, null, CancellationToken.None);
        var progress = new List<long>();

        await sender.SendFileAsync(request, path, new SyncProgress(progress), CancellationToken.None);

        Assert.Empty(progress);
    }

    [Fact]
    public async Task EmptyFileIsDoneAtOnce()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string path = Path.Combine(h.Root, "empty.txt");
        await File.WriteAllBytesAsync(path, []);

        await guest.Service.SendFileAsync(host.Id, path, null, CancellationToken.None);

        Assert.Equal(0, new FileInfo(Path.Combine(h.ReceivedRoot, "Guest PC", "empty.txt")).Length);
    }

    [Fact]
    public async Task UnreachableHostFailsAfterTheRetriesAreSpent()
    {
        using var sender = new HostSender(_ => throw new IOException("down"), [TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(10)]);

        var failure = await Assert.ThrowsAsync<IOException>(() => sender.SendTextAsync("x", CancellationToken.None));

        Assert.Equal("down", failure.Message);
    }

    private sealed class SyncProgress(List<long> into) : IProgress<long>
    {
        public void Report(long value) => into.Add(value);
    }

    /// <summary>The offset once it stops changing: the host keeps what it read before the connection died, which can be less than what was sent.</summary>
    private static async Task<long> SettledOffsetAsync(Phone phone, string id)
    {
        long last = -1;
        for (int i = 0; i < 100; i++)
        {
            long offset = (await phone.GetStateAsync(id)).Offset;
            if (offset == last) return offset;
            last = offset;
            await Task.Delay(150);
        }
        return last;
    }
}

public class GuestReceiveTests
{
    [Fact]
    public async Task TextAndLinkGoToTheHistoryOnceAndAreAcknowledged()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        var text = h.Service.Outbox.QueueText(guest.GuestId, "from the host");
        var link = h.Service.Outbox.QueueLink(guest.GuestId, "https://alazy.app/");
        var received = new List<ReceivedItem>();
        guest.Service.Receiver.TextReceived += (_, item) => received.Add(item);
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        int taken = await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        Assert.Equal(2, taken);
        Assert.Equal([text.Id, link.Id], received.Select(i => i.Id));
        Assert.Equal("Test PC", received[0].DeviceName);
        Assert.Empty(h.Service.Outbox.Pending(guest.GuestId));
        Assert.Equal(2, guest.History.Items.Count);
    }

    [Fact]
    public async Task ItemAlreadyInTheHistoryIsNotAddedAgain()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        var text = h.Service.Outbox.QueueText(guest.GuestId, "again");
        guest.History.Add(new PairedDevice { Id = host.Id, Name = host.Name }, ItemKind.Text, "again", null, DateTimeOffset.UtcNow, text.Id);
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        Assert.Single(guest.History.Items);
        Assert.Empty(h.Service.Outbox.Pending(guest.GuestId));
    }

    [Fact]
    public async Task FileLandsInTheHostsFolderMarkedAsDownloaded()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string source = Path.Combine(h.Root, "photo.jpg");
        byte[] content = RandomNumberGenerator.GetBytes(300_000);
        await File.WriteAllBytesAsync(source, content);
        h.Service.Outbox.QueueFile(guest.GuestId, source);
        ReceivedFile? arrived = null;
        guest.Service.Receiver.FileReceived += (_, file) => arrived = file;
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        string expected = Path.Combine(guest.Paths.DefaultReceiveRoot, "Test PC", "photo.jpg");
        Assert.Equal(expected, arrived?.Path);
        Assert.Equal(content, await File.ReadAllBytesAsync(expected));
        Assert.Contains("ZoneId=3", await File.ReadAllTextAsync(expected + ":Zone.Identifier"));
        Assert.Empty(h.Service.Outbox.Pending(guest.GuestId));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(expected)!, "*.part"));
    }

    [Fact]
    public async Task HalfDownloadedFileContinuesWhereItStopped()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string source = Path.Combine(h.Root, "movie.bin");
        byte[] content = RandomNumberGenerator.GetBytes(200_000);
        await File.WriteAllBytesAsync(source, content);
        var item = h.Service.Outbox.QueueFile(guest.GuestId, source);
        // What an earlier try left behind is not downloaded again: the first 50000 bytes here are zeros, not the file's.
        string folder = Path.Combine(guest.Paths.DefaultReceiveRoot, "Test PC");
        Directory.CreateDirectory(folder);
        await File.WriteAllBytesAsync(Path.Combine(folder, item.Id + ".part"), new byte[50_000]);
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        byte[] expected = [.. new byte[50_000], .. content[50_000..]];
        Assert.Equal(expected, await File.ReadAllBytesAsync(Path.Combine(folder, "movie.bin")));
        Assert.Empty(h.Service.Outbox.Pending(guest.GuestId));
    }

    [Fact]
    public async Task SecondFileWithTheSameNameGetsANumber()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string source = Path.Combine(h.Root, "same.txt");
        await File.WriteAllTextAsync(source, "one");
        h.Service.Outbox.QueueFile(guest.GuestId, source);
        h.Service.Outbox.QueueFile(guest.GuestId, source);
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        string folder = Path.Combine(guest.Paths.DefaultReceiveRoot, "Test PC");
        Assert.Equal(["same (2).txt", "same.txt"], Directory.GetFiles(folder).Select(Path.GetFileName).Order());
    }

    [Fact]
    public async Task FileThatChangedOnTheHostIsDroppedWithAMessage()
    {
        await using var h = new Harness();
        using var guest = new GuestRig(h);
        var host = await guest.PairAsync();
        string source = Path.Combine(h.Root, "moved.txt");
        await File.WriteAllTextAsync(source, "before");
        h.Service.Outbox.QueueFile(guest.GuestId, source);
        await File.WriteAllTextAsync(source, "after, and longer");
        string? failure = null;
        guest.Service.Receiver.Failed += (_, text) => failure = text;
        using var client = await guest.Service.Connector.ConnectAsync(host.Id, CancellationToken.None);

        await guest.Service.Receiver.CollectAsync(client, host.Id, 0, CancellationToken.None);

        Assert.Contains("moved.txt", failure);
        Assert.Empty(h.Service.Outbox.Pending(guest.GuestId));
    }
}

public class HostStoreTests
{
    [Fact]
    public void SecretIsKeptProtectedAndSurvivesAReload()
    {
        string path = Path.Combine(Path.GetTempPath(), "lazysend-hosts-" + Guid.NewGuid().ToString("N"), "hosts.json");
        try
        {
            string secret = Protocol.EncodeBase64Url(RandomNumberGenerator.GetBytes(PairedDeviceStore.SecretByteCount));
            var store = new HostStore(path);
            store.Add(new GuestHost { Id = Protocol.NewId(), Name = "Mac", Fingerprint = "f", Addresses = ["10.0.0.2"], Port = 52734 }, secret);

            var again = new HostStore(path);
            var host = Assert.Single(again.Hosts);

            Assert.Equal(secret, again.Secret(host.Id));
            Assert.DoesNotContain(secret, File.ReadAllText(path));
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
        }
    }

    [Fact]
    public void AddressesMergeHelloFirstWithoutDuplicatesScopesOrMoreThanEight()
    {
        var merged = HostStore.MergeAddresses(["10.0.0.9", "10.0.0.2"], ["10.0.0.2", "fe80::1%12", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6", "10.0.0.7", "10.0.0.8"]);

        Assert.Equal(["10.0.0.9", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6", "10.0.0.7", "10.0.0.8"], merged);
    }
}
