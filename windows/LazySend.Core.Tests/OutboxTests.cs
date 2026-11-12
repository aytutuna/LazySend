using System.Diagnostics;
using System.Net;
using LazySend.Core;

namespace LazySend.Core.Tests;

public class OutboxTests
{
    private static string WriteFile(Harness h, string name, int length)
    {
        string path = Path.Combine(h.Root, "pc", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var data = new byte[length];
        new Random(7).NextBytes(data);
        File.WriteAllBytes(path, data);
        return path;
    }

    private static async Task<OutboxResponse> PollAsync(Phone phone, int wait)
    {
        using var response = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPath}?wait={wait}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await Harness.ReadAsync<OutboxResponse>(response);
    }

    [Fact]
    public async Task PollReturnsPendingItemsAtOnce()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Outbox.QueueText(phone.Id, "hello phone");
        h.Service.Outbox.QueueLink(phone.Id, "https://alazy.app/");

        var items = (await PollAsync(phone, 0)).Items;

        Assert.Equal([ItemKind.Text, ItemKind.Link], items.Select(i => i.Kind));
        Assert.Equal("hello phone", items[0].Text);
        Assert.Equal("https://alazy.app/", items[1].Url);
    }

    [Fact]
    public async Task LongPollReturnsAsSoonAsSomethingIsQueued()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var watch = Stopwatch.StartNew();
        var poll = PollAsync(phone, 20);

        await Task.Delay(400);
        Assert.False(poll.IsCompleted);
        h.Service.Outbox.QueueText(phone.Id, "now");
        var result = await poll.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal("now", Assert.Single(result.Items).Text);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
    }

    [Fact]
    public async Task LongPollWithNothingQueuedEndsEmptyAtTheTimeout()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var watch = Stopwatch.StartNew();

        var result = await PollAsync(phone, 1);

        Assert.Empty(result.Items);
        Assert.InRange(watch.Elapsed, TimeSpan.FromMilliseconds(800), TimeSpan.FromSeconds(10));
    }

    [Fact]
    public async Task ItemsQueuedForAnotherPhoneDoNotWakeThisOne()
    {
        await using var h = new Harness();
        using var one = await h.PairAsync("One");
        using var two = await h.PairAsync("Two");
        var poll = PollAsync(two, 1);

        h.Service.Outbox.QueueText(one.Id, "for one");

        Assert.Empty((await poll).Items);
        Assert.Single((await PollAsync(one, 0)).Items);
    }

    [Fact]
    public async Task WaitIsCappedAndMustBeANumber()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Outbox.QueueText(phone.Id, "x");

        using var bad = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPath}?wait=soon");
        var capped = await PollAsync(phone, 9999);

        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        Assert.Single(capped.Items);
    }

    [Fact]
    public async Task FileDownloadsWholeAndByRange()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        string path = WriteFile(h, "photo.jpg", 100_000);
        byte[] expected = await File.ReadAllBytesAsync(path);
        var item = h.Service.Outbox.QueueFile(phone.Id, path, "image/jpeg");
        var entry = Assert.Single((await PollAsync(phone, 0)).Items);
        Assert.Equal("photo.jpg", entry.Name);
        Assert.Equal(100_000, entry.Size);
        Assert.Equal("image/jpeg", entry.Mime);
        Assert.Equal(item.Id, entry.Id);

        using var whole = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPrefix}{item.Id}/data");
        Assert.Equal(HttpStatusCode.OK, whole.StatusCode);
        Assert.Equal(expected, await whole.Content.ReadAsByteArrayAsync());

        // A download that broke after 40,000 bytes resumes there.
        using var rest = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPrefix}{item.Id}/data", null, true, ("Range", "bytes=40000-"));
        Assert.Equal(HttpStatusCode.PartialContent, rest.StatusCode);
        Assert.Equal(40_000, rest.Content.Headers.ContentRange?.From);
        Assert.Equal(99_999, rest.Content.Headers.ContentRange?.To);
        Assert.Equal(100_000, rest.Content.Headers.ContentRange?.Length);
        Assert.Equal(expected[40_000..], await rest.Content.ReadAsByteArrayAsync());
    }

    [Fact]
    public async Task BadRangesAreRefused()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var item = h.Service.Outbox.QueueFile(phone.Id, WriteFile(h, "a.bin", 1000));
        string url = $"{Protocol.OutboxPrefix}{item.Id}/data";

        foreach (string range in new[] { "bytes=1000-", "bytes=5000-", "bytes=0-99", "bytes=-5", "items=1-", "bytes=x-" })
        {
            using var response = await phone.SendAsync(HttpMethod.Get, url, null, true, ("Range", range));
            Assert.Equal(HttpStatusCode.RequestedRangeNotSatisfiable, response.StatusCode);
        }
    }

    [Fact]
    public async Task FileThatChangedOrWentIsNotServed()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        string path = WriteFile(h, "a.bin", 1000);
        var item = h.Service.Outbox.QueueFile(phone.Id, path);

        await File.AppendAllTextAsync(path, "more");
        using var changed = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPrefix}{item.Id}/data");
        Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode);

        File.Delete(path);
        using var gone = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPrefix}{item.Id}/data");
        Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);
    }

    [Fact]
    public async Task AcknowledgingRemovesTheItemAndOnlyThatOne()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        var first = h.Service.Outbox.QueueText(phone.Id, "first");
        h.Service.Outbox.QueueText(phone.Id, "second");

        using var ack = await phone.SendAsync(HttpMethod.Delete, Protocol.OutboxPrefix + first.Id);
        using var again = await phone.SendAsync(HttpMethod.Delete, Protocol.OutboxPrefix + first.Id);

        Assert.Equal(HttpStatusCode.NoContent, ack.StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, again.StatusCode);
        Assert.Equal("second", Assert.Single((await PollAsync(phone, 0)).Items).Text);
    }

    [Fact]
    public async Task AnotherPhoneCannotAcknowledgeOrDownload()
    {
        await using var h = new Harness();
        using var one = await h.PairAsync("One");
        using var two = await h.PairAsync("Two");
        var item = h.Service.Outbox.QueueFile(one.Id, WriteFile(h, "a.bin", 10));

        using var ack = await two.SendAsync(HttpMethod.Delete, Protocol.OutboxPrefix + item.Id);
        using var data = await two.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPrefix}{item.Id}/data");

        Assert.Equal(HttpStatusCode.NotFound, data.StatusCode);
        Assert.Single((await PollAsync(one, 0)).Items);
    }

    [Fact]
    public async Task OutboxSurvivesARestartUntilAcknowledged()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Outbox.QueueText(phone.Id, "kept");
        var file = h.Service.Outbox.QueueFile(phone.Id, WriteFile(h, "a.bin", 10));

        await h.RestartAsync();

        Assert.Equal(["kept", null], (await PollAsync(phone, 0)).Items.Select(i => i.Text));
        using var ack = await phone.SendAsync(HttpMethod.Delete, Protocol.OutboxPrefix + file.Id);
        await h.RestartAsync();
        Assert.Equal("kept", Assert.Single((await PollAsync(phone, 0)).Items).Text);
    }

    [Fact]
    public async Task QueueRefusesWhatCannotBeSent()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();

        Assert.Throws<FileNotFoundException>(() => h.Service.Outbox.QueueFile(phone.Id, Path.Combine(h.Root, "none.bin")));
        Assert.Throws<ArgumentException>(() => h.Service.Outbox.QueueLink(phone.Id, "javascript:alert(1)"));
        Assert.Throws<ArgumentException>(() => h.Service.Outbox.QueueText(phone.Id, ""));
    }
}

public class OutboxLimitTests
{
    private static async Task<OutboxResponse> PollAsync(Phone phone)
    {
        using var response = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPath}?wait=0");
        return await Harness.ReadAsync<OutboxResponse>(response);
    }

    [Fact]
    public async Task ReplyHoldsAtMostAHundredItems()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        for (int i = 0; i < 150; i++) h.Service.Outbox.QueueText(phone.Id, $"note {i}");

        var reply = await PollAsync(phone);

        Assert.Equal(100, reply.Items.Count);
        Assert.True(reply.More);
        foreach (var item in reply.Items) h.Service.Outbox.Acknowledge(phone.Id, item.Id);
        var rest = await PollAsync(phone);
        Assert.Equal(50, rest.Items.Count);
        Assert.Null(rest.More);
    }

    [Fact]
    public async Task ReplyHoldsAtMostFourMebibytesOfText()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        for (int i = 0; i < 5; i++) h.Service.Outbox.QueueText(phone.Id, new string('x', Protocol.MaxTextBytes));

        var reply = await PollAsync(phone);

        Assert.Equal(4, reply.Items.Count);
        Assert.True(reply.More);
    }

    [Fact]
    public async Task RemovingAPhoneOnTheComputerClearsWhatWaitsForIt()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        h.Service.Outbox.QueueText(phone.Id, "waiting");
        var state = await phone.BeginFileAsync("a.bin", new byte[100]);

        h.Service.Devices.Remove(phone.Id);

        Assert.Empty(h.Service.Outbox.Pending(phone.Id));
        Assert.Empty(h.Service.Inbox.InProgress);
        Assert.Null(h.Service.Inbox.State(phone.Id, state.Id));
    }

    [Fact]
    public void ClearingAnIndexThatWasNeverWrittenIsFine()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazysend-none-" + Guid.NewGuid().ToString("N"));

        new GalleryIndex(folder).Clear("device-one");
    }
}

public class OutboxBatchTests
{
    [Fact]
    public async Task ManyFilesAreQueuedWithOneSave()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        string folder = Path.Combine(h.Root, "many");
        Directory.CreateDirectory(folder);
        var paths = Enumerable.Range(0, 1000).Select(i =>
        {
            string path = Path.Combine(folder, $"f{i}.txt");
            File.WriteAllText(path, "x");
            return path;
        }).ToList();
        int changes = 0;
        h.Service.Outbox.Changed += (_, _) => changes++;

        var queued = h.Service.Outbox.QueueFiles(phone.Id, paths);

        Assert.Equal(1000, queued.Count);
        Assert.Equal(1, changes);
        Assert.Equal(1000, new Outbox(h.Paths.OutboxFile).Pending(phone.Id).Count);
    }

    [Fact]
    public async Task BatchStopsAtTheLimitAndSkipsMissingFiles()
    {
        await using var h = new Harness();
        using var phone = await h.PairAsync();
        string folder = Path.Combine(h.Root, "some");
        Directory.CreateDirectory(folder);
        var paths = Enumerable.Range(0, Outbox.MaxItemsPerDevice + 5).Select(i =>
        {
            string path = Path.Combine(folder, $"f{i}.txt");
            File.WriteAllText(path, "x");
            return path;
        }).Append(Path.Combine(folder, "missing.txt")).ToList();

        var queued = h.Service.Outbox.QueueFiles(phone.Id, paths);

        Assert.Equal(Outbox.MaxItemsPerDevice, queued.Count);
        Assert.Empty(h.Service.Outbox.QueueFiles(phone.Id, [Path.Combine(folder, "f1.txt")]));
    }
}
