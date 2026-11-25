using System.Security.Cryptography;
using System.Net;
using LazySend.Core;

namespace LazySend.Core.Tests;

public class InboxTests
{
    private static byte[] Bytes(int length)
    {
        var data = new byte[length];
        new Random(3).NextBytes(data);
        return data;
    }

    private static string PartOf(Harness h, string id) =>
        Path.Combine(h.Service.Inbox.InProgress.Single(f => f.Id == id).Directory, id + ".part");

    [Fact]
    public async Task FullPartIsFinishedWhenItsStateIsAsked()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(5000);
        var state = await phone.BeginFileAsync("a.bin", content);
        await File.WriteAllBytesAsync(PartOf(h, state.Id), content);

        var after = await phone.GetStateAsync(state.Id);

        Assert.True(after.Done);
        Assert.Equal(content, await File.ReadAllBytesAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "a.bin")));
    }

    [Fact]
    public async Task FullPartIsFinishedAtStartup()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(5000);
        var state = await phone.BeginFileAsync("a.bin", content);
        await File.WriteAllBytesAsync(PartOf(h, state.Id), content);

        await h.RestartAsync();

        Assert.True((await phone.GetStateAsync(state.Id)).Done);
        Assert.True(File.Exists(Path.Combine(h.ReceivedRoot, "Test iPhone", "a.bin")));
    }

    [Fact]
    public async Task EmptyPutAtTheEndFinishesAFullPart()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(5000);
        var state = await phone.BeginFileAsync("a.bin", content);
        string part = PartOf(h, state.Id);
        await File.WriteAllBytesAsync(part, content);

        // The part is full but this request is the first to look at it.
        using var response = await phone.PutChunkAsync(state.Id, content.Length, []);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True((await Harness.ReadAsync<ItemState>(response)).Done);
    }

    [Fact]
    public async Task EmptyPutBeforeTheEndIsAMismatch()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var state = await phone.BeginFileAsync("a.bin", Bytes(5000));

        using var response = await phone.PutChunkAsync(state.Id, 5000, []);

        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
    }

    [Fact]
    public async Task GalleryPostForAFullPartFinishesItInsteadOfReturningTheStuckId()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(2000);
        var state = await phone.BeginFileAsync("a.jpg", content, sourceId: "asset-1");
        await File.WriteAllBytesAsync(PartOf(h, state.Id), content);

        var again = await phone.BeginFileAsync("a.jpg", content, sourceId: "asset-1");

        Assert.True(again.Done);
    }
}

public class ReinstalledPhoneTests
{
    private static async Task<ItemState> SendAsync(Harness h, string phoneId, byte[] content, string sourceId)
    {
        using var phone = await h.PairAsync("Test Pixel", phoneId);
        var state = await phone.BeginFileAsync("IMG_0012.jpg", content, sourceId: sourceId, modified: h.Now);
        if (!state.Done)
        {
            using var response = await phone.PutChunkAsync(state.Id, 0, content);
            response.EnsureSuccessStatusCode();
        }
        return state;
    }

    [Fact]
    public async Task ALibraryFileAlreadyOnTheComputerIsNotSavedAgainAfterAReinstall()
    {
        await using var h = new Harness();
        var content = RandomNumberGenerator.GetBytes(500);
        await SendAsync(h, Protocol.NewId(), content, "7:500:1");

        var again = await SendAsync(h, Protocol.NewId(), content, "9:500:1");

        Assert.True(again.Done);
        Assert.True(again.Duplicate);
        string month = Path.Combine(h.ReceivedRoot, "Test Pixel", "Gallery", h.Now.ToLocalTime().ToString("yyyy-MM"));
        Assert.Equal(["IMG_0012.jpg"], Directory.GetFiles(month).Select(Path.GetFileName));
    }

    [Fact]
    public async Task AnotherPhotoWithTheSameNameAndSizeIsSavedAsASecondFile()
    {
        await using var h = new Harness();
        await SendAsync(h, Protocol.NewId(), RandomNumberGenerator.GetBytes(500), "7:500:1");

        var other = await SendAsync(h, Protocol.NewId(), RandomNumberGenerator.GetBytes(500), "8:500:1");

        Assert.False(other.Done);
        string month = Path.Combine(h.ReceivedRoot, "Test Pixel", "Gallery", h.Now.ToLocalTime().ToString("yyyy-MM"));
        Assert.Equal(["IMG_0012 (2).jpg", "IMG_0012.jpg"], Directory.GetFiles(month).Select(Path.GetFileName).Order());
    }
}

public class ModifiedDateTests
{
    [Fact]
    public async Task ImplausibleModifiedDateStillReceivesTheFile()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[100];

        var state = await phone.BeginFileAsync("a.jpg", content, sourceId: "asset-1", modified: DateTimeOffset.MinValue);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);

        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
        Assert.True((await Harness.ReadAsync<ItemState>(response)).Done);
        string month = h.Now.ToLocalTime().ToString("yyyy-MM");
        Assert.True(File.Exists(Path.Combine(h.ReceivedRoot, "Test iPhone", "Gallery", month, "a.jpg")));
        using var check = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest(["asset-1"]));
        Assert.Empty((await Harness.ReadAsync<GalleryCheckResponse>(check)).Missing);
    }
}

public class InboxRaceTests
{
    [Fact]
    public async Task ConcurrentBeginsForOneAssetStartOneTransfer()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var device = h.Service.Devices.Devices.Single();
        var request = new ItemRequest(ItemKind.File, Name: "a.jpg", Size: 1000, SourceId: "asset-1");

        var ids = await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => Task.Run(() => h.Service.Inbox.Begin(device, request).Id)));

        Assert.Single(ids.Distinct());
        Assert.Single(h.Service.Inbox.InProgress);
    }

    [Fact]
    public async Task RemovedPhoneCannotWriteAndLeavesNoPartBehind()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[1000];
        var state = await phone.BeginFileAsync("a.bin", content);
        string folder = h.Service.Inbox.InProgress.Single().Directory;

        h.Service.Inbox.RemoveDevice(phone.Id);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);

        Assert.Empty(h.Service.Inbox.InProgress);
        Assert.Empty(Directory.GetFiles(folder));
        Assert.NotEqual(System.Net.HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task PartDeletedBehindOurBackDropsTheRecord()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[1000];
        var state = await phone.BeginFileAsync("a.bin", content);
        var file = h.Service.Inbox.InProgress.Single();
        File.Delete(Path.Combine(file.Directory, file.Id + ".part"));

        using var response = await phone.PutChunkAsync(state.Id, 0, content);

        Assert.Equal(System.Net.HttpStatusCode.NotFound, response.StatusCode);
        Assert.Empty(h.Service.Inbox.InProgress);
    }
}

public class InboxPruneTests
{
    [Fact]
    public async Task FinishedRecordsAreDroppedWhileRunning()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[100];
        var first = await phone.BeginFileAsync("a.bin", content);
        using (var response = await phone.PutChunkAsync(first.Id, 0, content)) response.EnsureSuccessStatusCode();
        Assert.True((await phone.GetStateAsync(first.Id)).Done);

        h.Now += TimeSpan.FromDays(2);
        await phone.BeginFileAsync("b.bin", content);

        Assert.Null(h.Service.Inbox.State(phone.Id, first.Id));
        Assert.Empty(Directory.GetFiles(h.Paths.IncomingDirectory).Where(p => p.Contains(first.Id)));
    }

    [Fact]
    public async Task ManyGalleryStartsStayQuick()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var device = h.Service.Devices.Devices.Single();
        var watch = System.Diagnostics.Stopwatch.StartNew();

        for (int i = 0; i < 3000; i++)
        {
            h.Service.Inbox.Begin(device, new ItemRequest(ItemKind.File, Name: $"{i}.jpg", Size: 10, SourceId: $"asset-{i}"));
        }

        Assert.Equal(3000, h.Service.Inbox.InProgress.Count);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(60));
    }
}

public class ZoneTests
{
    [Fact]
    public async Task ReceivedFilesAreMarkedAsDownloaded()
    {
        if (!OperatingSystem.IsWindows()) return;
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[100];
        var state = await phone.BeginFileAsync("setup.exe", content);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);
        response.EnsureSuccessStatusCode();

        string mark = await File.ReadAllTextAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "setup.exe") + ":Zone.Identifier");

        Assert.Contains("ZoneId=3", mark);
    }
}

public class SendIdTests
{
    private const string SendId = "AbCdEfGhIjKlMnOpQrStUv";

    private static ItemRequest FileRequest(byte[] content, string sendId = SendId) =>
        new(ItemKind.File, Name: "a.bin", Size: content.Length, SendId: sendId);

    [Fact]
    public async Task RepeatInProgressGivesTheCurrentOffset()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[5000];
        using var first = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));
        var begun = await Harness.ReadAsync<ItemState>(first);
        (await phone.PutChunkAsync(begun.Id, 0, content[..2000])).EnsureSuccessStatusCode();

        using var again = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));

        Assert.Equal(System.Net.HttpStatusCode.OK, again.StatusCode);
        Assert.Equal(new ItemState(begun.Id, 2000, false), await Harness.ReadAsync<ItemState>(again));
        Assert.Single(h.Service.Inbox.InProgress);
    }

    [Fact]
    public async Task RepeatFinishedIsDoneAndAddsNothing()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[5000];
        using var first = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));
        var begun = await Harness.ReadAsync<ItemState>(first);
        (await phone.PutChunkAsync(begun.Id, 0, content)).EnsureSuccessStatusCode();
        int received = 0;
        h.Service.Inbox.FileReceived += (_, _) => received++;

        await h.RestartAsync();
        h.Service.Inbox.FileReceived += (_, _) => received++;
        using var again = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));

        Assert.Equal(System.Net.HttpStatusCode.OK, again.StatusCode);
        Assert.Equal(new ItemState(begun.Id, 5000, true), await Harness.ReadAsync<ItemState>(again));
        Assert.Equal(0, received);
        Assert.Single(Directory.GetFiles(Path.Combine(h.ReceivedRoot, "Test iPhone")));
    }

    [Fact]
    public async Task RepeatInProgressSurvivesARestart()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = new byte[5000];
        using var first = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));
        var begun = await Harness.ReadAsync<ItemState>(first);
        (await phone.PutChunkAsync(begun.Id, 0, content[..1500])).EnsureSuccessStatusCode();

        await h.RestartAsync();
        using var again = await phone.PostAsync(Protocol.ItemsPath, FileRequest(content));

        Assert.Equal(new ItemState(begun.Id, 1500, false), await Harness.ReadAsync<ItemState>(again));
    }

    [Fact]
    public async Task OtherSizeOrKindWithTheSameSendIdIsRefused()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        (await phone.PostAsync(Protocol.ItemsPath, FileRequest(new byte[100]))).EnsureSuccessStatusCode();

        using var size = await phone.PostAsync(Protocol.ItemsPath, FileRequest(new byte[101]));
        using var kind = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: "hi", SendId: SendId));

        Assert.Equal(System.Net.HttpStatusCode.BadRequest, size.StatusCode);
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, kind.StatusCode);
    }

    [Theory]
    [InlineData("short")]
    [InlineData("0123456789abcde")]
    [InlineData("0123456789abcdef!")]
    [InlineData("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0")]
    public async Task MalformedSendIdIsRefused(string sendId)
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        using var file = await phone.PostAsync(Protocol.ItemsPath, FileRequest(new byte[10], sendId));
        using var text = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: "hi", SendId: sendId));

        Assert.Equal(System.Net.HttpStatusCode.BadRequest, file.StatusCode);
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, text.StatusCode);
    }

    [Fact]
    public async Task RepeatedTextAndLinkAddNoSecondHistoryEntry()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var text = new ItemRequest(ItemKind.Text, Text: "hello", SendId: SendId);
        var link = new ItemRequest(ItemKind.Link, Url: "https://alazy.app/", SendId: "ZyXwVuTsRqPoNmLkJiHgFe");
        var firstText = await Harness.ReadAsync<ItemState>(await phone.PostAsync(Protocol.ItemsPath, text));
        await phone.PostAsync(Protocol.ItemsPath, link);

        await h.RestartAsync();
        using var again = await phone.PostAsync(Protocol.ItemsPath, text);
        await phone.PostAsync(Protocol.ItemsPath, link);

        Assert.Equal(System.Net.HttpStatusCode.OK, again.StatusCode);
        Assert.Equal(firstText, await Harness.ReadAsync<ItemState>(again));
        Assert.Equal(2, h.Service.History.Items.Count);
    }

    [Fact]
    public async Task SendIdIsScopedToTheDevice()
    {
        await using var h = new Harness();
        using var one = await h.PairAsync("One");
        using var two = await h.PairAsync("Two");

        var a = await Harness.ReadAsync<ItemState>(await one.PostAsync(Protocol.ItemsPath, FileRequest(new byte[10])));
        var b = await Harness.ReadAsync<ItemState>(await two.PostAsync(Protocol.ItemsPath, FileRequest(new byte[10])));

        Assert.NotEqual(a.Id, b.Id);
    }
}
