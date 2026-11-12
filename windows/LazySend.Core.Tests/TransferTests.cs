using System.Net;
using System.Security.Cryptography;
using LazySend.Core;

namespace LazySend.Core.Tests;

public class TransferTests
{
    private static byte[] Bytes(int length, int seed = 1)
    {
        var data = new byte[length];
        new Random(seed).NextBytes(data);
        return data;
    }

    /// <summary>The offset once it stops changing: the desktop keeps what it read before a connection died, which can be less than what was sent.</summary>
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

    [Fact]
    public async Task TextAndLinkAreStoredAtOnceNewestFirst()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Aytu's iPhone");
        var seen = new List<ReceivedItem>();
        h.Service.Router.TextReceived += (_, item) => seen.Add(item);

        using var text = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: "meeting at 5"));
        h.Now += TimeSpan.FromSeconds(1);
        using var link = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Link, Url: "https://alazy.app/send/"));

        Assert.Equal(HttpStatusCode.Created, text.StatusCode);
        Assert.Equal(HttpStatusCode.Created, link.StatusCode);
        var items = h.Service.History.Items;
        Assert.Equal([ItemKind.Link, ItemKind.Text], items.Select(i => i.Kind));
        Assert.Equal("meeting at 5", items[1].Text);
        Assert.Equal("https://alazy.app/send/", items[0].Url);
        Assert.Equal("Aytu's iPhone", items[0].DeviceName);
        Assert.Equal(2, seen.Count);

        await h.RestartAsync();
        Assert.Equal(2, h.Service.History.Items.Count);
    }

    [Fact]
    public async Task BadTextAndLinksAreRefused()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        using var empty = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: ""));
        using var big = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: new string('a', Protocol.MaxTextBytes + 1)));
        using var fileLink = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Link, Url: "file:///c:/windows/system32/calc.exe"));
        using var unknown = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest("video"));
        using var maximum = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.Text, Text: new string('a', Protocol.MaxTextBytes)));

        Assert.Equal(HttpStatusCode.BadRequest, empty.StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, big.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, fileLink.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, unknown.StatusCode);
        Assert.Equal(HttpStatusCode.Created, maximum.StatusCode);
    }

    [Fact]
    public async Task FileUploadInChunksIsRenamedIntoPlace()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Aytu's iPhone");
        var content = Bytes(300_000);
        ReceivedFile? received = null;
        h.Service.Inbox.FileReceived += (_, file) => received = file;

        var state = await phone.BeginFileAsync("holiday.bin", content);
        Assert.Equal(0, state.Offset);
        Assert.False(state.Done);
        long offset = 0;
        foreach (int size in new[] { 100_000, 150_000, 50_000 })
        {
            using var response = await phone.PutChunkAsync(state.Id, offset, content[(int)offset..(int)(offset + size)]);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            var after = await Harness.ReadAsync<ItemState>(response);
            offset += size;
            Assert.Equal(offset, after.Offset);
            Assert.Equal(offset == content.Length, after.Done);
        }

        string path = Path.Combine(h.ReceivedRoot, "Aytu's iPhone", "holiday.bin");
        Assert.Equal(content, await File.ReadAllBytesAsync(path));
        Assert.Equal(path, received?.Path);
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(path)!, "*.part"));
        Assert.True((await phone.GetStateAsync(state.Id)).Done);
    }

    [Fact]
    public async Task SecondFileWithTheSameNameGetsASuffix()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Phone one");
        for (int i = 0; i < 2; i++)
        {
            var content = Bytes(1000, i);
            var state = await phone.BeginFileAsync("report.pdf", content);
            using var response = await phone.PutChunkAsync(state.Id, 0, content);
            response.EnsureSuccessStatusCode();
        }

        string folder = Path.Combine(h.ReceivedRoot, "Phone one");
        Assert.Equal(["report (2).pdf", "report.pdf"], Directory.GetFiles(folder).Select(Path.GetFileName).Order());
    }

    [Fact]
    public async Task NamesFromThePhoneAreMadeSafe()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Phone");
        var content = Bytes(10);
        var state = await phone.BeginFileAsync(@"..\..\evil:name?.txt", content);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);
        response.EnsureSuccessStatusCode();

        string file = Directory.GetFiles(Path.Combine(h.ReceivedRoot, "Phone")).Single();
        Assert.Equal(".._.._evil_name_.txt", Path.GetFileName(file));
    }

    [Fact]
    public async Task UploadResumesAfterADroppedConnection()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(500_000);
        var state = await phone.BeginFileAsync("movie.mp4", content);
        using (var first = await phone.PutChunkAsync(state.Id, 0, content[..100_000])) first.EnsureSuccessStatusCode();

        // The next chunk starts and the connection drops after 60,000 of its 200,000 bytes.
        await phone.DropMidChunkAsync(state.Id, 100_000, 200_000, content[100_000..160_000]);
        await Task.Delay(300);
        long offset = await SettledOffsetAsync(phone, state.Id);
        Assert.InRange(offset, 100_000, 160_000);
        Assert.False((await phone.GetStateAsync(state.Id)).Done);
        using var rest = await phone.PutChunkAsync(state.Id, offset, content[(int)offset..]);
        Assert.Equal(HttpStatusCode.OK, rest.StatusCode);
        Assert.True((await Harness.ReadAsync<ItemState>(rest)).Done);
        Assert.Equal(content, await File.ReadAllBytesAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "movie.mp4")));
    }

    [Fact]
    public async Task UploadResumesAfterTheAppRestarts()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(200_000);
        var state = await phone.BeginFileAsync("backup.zip", content);
        using (var first = await phone.PutChunkAsync(state.Id, 0, content[..120_000])) first.EnsureSuccessStatusCode();

        await h.RestartAsync();

        var resumed = await phone.GetStateAsync(state.Id);
        Assert.Equal(120_000, resumed.Offset);
        using var rest = await phone.PutChunkAsync(state.Id, 120_000, content[120_000..]);
        Assert.True((await Harness.ReadAsync<ItemState>(rest)).Done);
        Assert.Equal(content, await File.ReadAllBytesAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "backup.zip")));
    }

    [Fact]
    public async Task NewChunkTakesOverFromAHalfOpenOne()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(100_000);
        var state = await phone.BeginFileAsync("slow.bin", content);

        // The old connection is still open from the desktop's side when the phone comes back.
        await phone.DropMidChunkAsync(state.Id, 0, 100_000, content[..30_000]);
        using var again = await phone.PutChunkAsync(state.Id, 0, content);

        // Either the old writer had already stopped at 30,000, or the new chunk was ahead of it.
        Assert.Contains(again.StatusCode, new[] { HttpStatusCode.OK, HttpStatusCode.Conflict });
        if (again.StatusCode == HttpStatusCode.Conflict)
        {
            var mismatch = await Harness.ReadAsync<LinkError>(again);
            Assert.Equal(ErrorCode.OffsetMismatch, mismatch.Error);
            using var rest = await phone.PutChunkAsync(state.Id, mismatch.Offset!.Value, content[(int)mismatch.Offset.Value..]);
            Assert.Equal(HttpStatusCode.OK, rest.StatusCode);
        }
        Assert.Equal(content, await File.ReadAllBytesAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "slow.bin")));
    }

    [Fact]
    public async Task WrongOffsetGetsConflictWithTheCurrentOffset()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(100_000);
        var state = await phone.BeginFileAsync("a.bin", content);
        using (var first = await phone.PutChunkAsync(state.Id, 0, content[..40_000])) first.EnsureSuccessStatusCode();

        using var ahead = await phone.PutChunkAsync(state.Id, 50_000, content[50_000..]);
        using var behind = await phone.PutChunkAsync(state.Id, 10_000, content[10_000..50_000]);

        foreach (var response in new[] { ahead, behind })
        {
            Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
            var error = await Harness.ReadAsync<LinkError>(response);
            Assert.Equal(ErrorCode.OffsetMismatch, error.Error);
            Assert.Equal(40_000, error.Offset);
        }
        Assert.Equal(40_000, (await phone.GetStateAsync(state.Id)).Offset);
    }

    [Fact]
    public async Task ChunkPastTheEndOrWithoutOffsetIsRefused()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(1000);
        var state = await phone.BeginFileAsync("a.bin", content);

        using var tooLong = await phone.PutChunkAsync(state.Id, 0, Bytes(1001));
        using var noOffset = await phone.SendAsync(HttpMethod.Put, $"{Protocol.ItemsPrefix}{state.Id}/data", new ByteArrayContent(content));
        using var unknown = await phone.PutChunkAsync(Protocol.NewId(), 0, content);

        Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, noOffset.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
    }

    [Fact]
    public async Task WrongSha256DiscardsTheFile()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(5000);
        var request = new ItemRequest(ItemKind.File, Name: "doc.pdf", Size: content.Length, Sha256: new string('0', 64));
        using var begin = await phone.PostAsync(Protocol.ItemsPath, request);
        var state = await Harness.ReadAsync<ItemState>(begin);

        using var response = await phone.PutChunkAsync(state.Id, 0, content);

        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        Assert.Equal(ErrorCode.HashMismatch, await Harness.ErrorCodeAsync(response));
        string folder = Path.Combine(h.ReceivedRoot, "Test iPhone");
        Assert.Empty(Directory.GetFiles(folder));
        using var after = await phone.SendAsync(HttpMethod.Get, Protocol.ItemsPrefix + state.Id);
        Assert.Equal(HttpStatusCode.NotFound, after.StatusCode);
    }

    [Fact]
    public async Task Sha256IsCheckedAfterAResumeToo()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(100_000);
        var state = await phone.BeginFileAsync("a.bin", content);
        using (var first = await phone.PutChunkAsync(state.Id, 0, content[..50_000])) first.EnsureSuccessStatusCode();
        await h.RestartAsync();

        using var rest = await phone.PutChunkAsync(state.Id, 50_000, content[50_000..]);

        Assert.Equal(HttpStatusCode.OK, rest.StatusCode);
        Assert.True(File.Exists(Path.Combine(h.ReceivedRoot, "Test iPhone", "a.bin")));
    }

    [Fact]
    public async Task EmptyFileIsDoneAtOnce()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        var state = await phone.BeginFileAsync("empty.txt", []);

        Assert.True(state.Done);
        Assert.Empty(await File.ReadAllBytesAsync(Path.Combine(h.ReceivedRoot, "Test iPhone", "empty.txt")));
    }

    [Fact]
    public async Task RefusesWhenTheDriveWouldDropUnderOneGibibyte()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(1000);
        h.FreeBytes = Protocol.MinFreeBytes + 999;

        using var refused = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.File, Name: "a.bin", Size: content.Length));
        Assert.Equal(HttpStatusCode.InsufficientStorage, refused.StatusCode);
        Assert.Equal(ErrorCode.DiskFull, await Harness.ErrorCodeAsync(refused));

        h.FreeBytes = Protocol.MinFreeBytes + 1000;
        var state = await phone.BeginFileAsync("a.bin", content);
        h.FreeBytes = Protocol.MinFreeBytes;
        using var chunk = await phone.PutChunkAsync(state.Id, 0, content);
        Assert.Equal(HttpStatusCode.InsufficientStorage, chunk.StatusCode);
    }

    [Fact]
    public async Task OneItemOfAnotherPhoneIsNotVisible()
    {
        await using var h = new Harness();
        using var one = await h.PairAsync("One");
        using var two = await h.PairAsync("Two");
        var state = await one.BeginFileAsync("a.bin", Bytes(10));

        using var peek = await two.SendAsync(HttpMethod.Get, Protocol.ItemsPrefix + state.Id);
        using var write = await two.PutChunkAsync(state.Id, 0, Bytes(10));

        Assert.Equal(HttpStatusCode.NotFound, peek.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, write.StatusCode);
    }

    [Fact]
    public async Task GalleryItemsGoToAMonthFolderByTheirModifiedDate()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Aytu's iPhone");
        var content = Bytes(2000);
        var modified = new DateTimeOffset(2024, 7, 15, 12, 30, 0, TimeSpan.Zero);

        var state = await phone.BeginFileAsync("IMG_0001.JPG", content, sourceId: "asset-1", modified: modified);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);
        response.EnsureSuccessStatusCode();

        string path = Path.Combine(h.ReceivedRoot, "Aytu's iPhone", "Gallery", "2024-07", "IMG_0001.JPG");
        Assert.Equal(content, await File.ReadAllBytesAsync(path));
        Assert.Equal(modified.UtcDateTime, File.GetLastWriteTimeUtc(path));
    }

    [Fact]
    public async Task GalleryCheckReturnsOnlyWhatIsNewAndSurvivesARestart()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        for (int i = 0; i < 3; i++)
        {
            var content = Bytes(500, i);
            var state = await phone.BeginFileAsync($"IMG_{i}.JPG", content, sourceId: $"asset-{i}");
            using var response = await phone.PutChunkAsync(state.Id, 0, content);
            response.EnsureSuccessStatusCode();
        }
        var ids = Enumerable.Range(0, 6).Select(i => $"asset-{i}").ToList();

        async Task<List<string>> Check()
        {
            using var response = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest(ids));
            response.EnsureSuccessStatusCode();
            return (await Harness.ReadAsync<GalleryCheckResponse>(response)).Missing;
        }

        Assert.Equal(["asset-3", "asset-4", "asset-5"], await Check());
        await h.RestartAsync();
        Assert.Equal(["asset-3", "asset-4", "asset-5"], await Check());

        using var again = await phone.PostAsync(Protocol.ItemsPath, new ItemRequest(ItemKind.File, Name: "IMG_0.JPG", Size: 500, SourceId: "asset-0"));
        Assert.Equal(HttpStatusCode.OK, again.StatusCode);
        var duplicate = await Harness.ReadAsync<ItemState>(again);
        Assert.True(duplicate.Done);
        Assert.True(duplicate.Duplicate);
    }

    [Fact]
    public async Task GalleryIndexIsPerPhone()
    {
        await using var h = new Harness();
        using var one = await h.PairAsync("One");
        using var two = await h.PairAsync("Two");
        var content = Bytes(100);
        var state = await one.BeginFileAsync("a.jpg", content, sourceId: "same-id");
        using (var response = await one.PutChunkAsync(state.Id, 0, content)) response.EnsureSuccessStatusCode();

        using var check = await two.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest(["same-id"]));

        Assert.Equal(["same-id"], (await Harness.ReadAsync<GalleryCheckResponse>(check)).Missing);
    }

    [Fact]
    public async Task UnfinishedGalleryFileIsNotCountedAsReceived()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var content = Bytes(1000);
        var state = await phone.BeginFileAsync("a.jpg", content, sourceId: "asset-1");
        using (var half = await phone.PutChunkAsync(state.Id, 0, content[..500])) half.EnsureSuccessStatusCode();

        using var check = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest(["asset-1"]));
        Assert.Equal(["asset-1"], (await Harness.ReadAsync<GalleryCheckResponse>(check)).Missing);

        // Starting it again finds the transfer in progress instead of making a second one.
        var again = await phone.BeginFileAsync("a.jpg", content, sourceId: "asset-1");
        Assert.Equal(state.Id, again.Id);
        Assert.Equal(500, again.Offset);
    }

    [Fact]
    public async Task GalleryCheckTakesAtMostAThousandIds()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        using var thousand = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest([.. Enumerable.Range(0, 1000).Select(i => $"a{i}")]));
        using var more = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest([.. Enumerable.Range(0, 1001).Select(i => $"a{i}")]));
        using var bad = await phone.PostAsync(Protocol.GalleryCheckPath, new GalleryCheckRequest(["fine", "bro\nken"]));

        Assert.Equal(HttpStatusCode.OK, thousand.StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, more.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
    }

    [Fact]
    public async Task ReceiveFolderCanBeMoved()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync("Phone");
        string elsewhere = Path.Combine(h.Root, "elsewhere");
        h.Service.Settings.ReceiveRoot = elsewhere;
        var content = Bytes(100);

        var state = await phone.BeginFileAsync("a.txt", content);
        using var response = await phone.PutChunkAsync(state.Id, 0, content);

        Assert.True(File.Exists(Path.Combine(elsewhere, "Phone", "a.txt")));
        await h.RestartAsync();
        Assert.Equal(elsewhere, h.Service.Settings.ReceiveRoot);
    }
}
