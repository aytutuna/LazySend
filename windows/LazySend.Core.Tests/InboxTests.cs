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
