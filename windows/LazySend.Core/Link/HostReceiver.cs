using System.Text;

namespace LazySend.Core;

/// <summary>
/// Takes what a host has queued for this computer: texts and links go into the received history, files
/// into <c>&lt;receive folder&gt;\&lt;host name&gt;\</c> as a <c>.part</c> file that a dropped download continues,
/// then each item is acknowledged. The host keeps an item until it is, so one that arrives twice is
/// noticed by its id in the history; a file whose acknowledgement was lost may be received again.
/// </summary>
public sealed class HostReceiver(HostStore hosts, ReceivedHistory history, SendSettings settings)
{
    private static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(30);

    public event EventHandler<ReceivedItem>? TextReceived;
    public event EventHandler<ReceivedFile>? FileReceived;

    /// <summary>An item could not be stored and was dropped from the host's queue; the argument says what and why.</summary>
    public event EventHandler<string>? Failed;

    /// <summary>
    /// Takes everything pending once; with <paramref name="waitSeconds"/> above 0 the request is held open until
    /// something comes. Returns how many items were taken. A host that is busy or out of reach leaves the rest queued and throws.
    /// </summary>
    public async Task<int> CollectAsync(LinkClient client, string hostId, int waitSeconds, CancellationToken cancellation)
    {
        int taken = 0;
        bool more = true;
        while (more)
        {
            var reply = await client.OutboxAsync(waitSeconds, cancellation).ConfigureAwait(false);
            more = reply.More == true;
            foreach (var item in reply.Items)
            {
                if (!Protocol.IsValidId(item.Id) || hosts.Find(hostId) is not { } host) continue;
                await HandleAsync(host, client, item, cancellation).ConfigureAwait(false);
                taken++;
            }
        }
        return taken;
    }

    private async Task HandleAsync(GuestHost host, LinkClient client, OutboxEntry item, CancellationToken cancellation)
    {
        try
        {
            switch (item.Kind)
            {
                case ItemKind.Text or ItemKind.Link:
                    AddText(host, item);
                    break;
                case ItemKind.File:
                    await DownloadAsync(host, client, item, cancellation).ConfigureAwait(false);
                    break;
            }
        }
        catch (LinkException e) when (!LeavesQueued(e))
        {
            Failed?.Invoke(this, $"{item.Name ?? "An item"} from {host.Name} could not be received: {e.Message}");
        }
        catch (LocalFailure e)
        {
            Failed?.Invoke(this, $"{item.Name ?? "An item"} from {host.Name} could not be saved: {e.Message}");
        }
        await client.AcknowledgeAsync(item.Id, cancellation).ConfigureAwait(false);
    }

    /// <summary>A refusal that goes away or is not about this item: the item stays queued.</summary>
    private static bool LeavesQueued(LinkException e) => e.IsBusy || e.Status is 401 or >= 500;

    private void AddText(GuestHost host, OutboxEntry item)
    {
        bool link = item.Kind == ItemKind.Link;
        if (history.Items.Any(i => i.Id == item.Id)) return;
        if (link ? !ReceivedLinks.IsAcceptable(item.Url) : string.IsNullOrEmpty(item.Text) || Encoding.UTF8.GetByteCount(item.Text) > Protocol.MaxTextBytes)
        {
            throw new LocalFailure("it is not text or a web address Lazy Send takes.");
        }
        var sender = new PairedDevice { Id = host.Id, Name = host.Name };
        var stored = history.Add(sender, item.Kind, link ? null : item.Text, link ? item.Url : null, DateTimeOffset.UtcNow, item.Id);
        TextReceived?.Invoke(this, stored);
    }

    private async Task DownloadAsync(GuestHost host, LinkClient client, OutboxEntry item, CancellationToken cancellation)
    {
        string directory = Path.Combine(settings.ReceiveRoot, FileNames.Clean(host.Name, "Computer"));
        string part = Path.Combine(directory, item.Id + ".part");
        long size = item.Size ?? -1;
        long have = Local(() =>
        {
            Directory.CreateDirectory(directory);
            return File.Exists(part) ? new FileInfo(part).Length : 0;
        });
        if (size >= 0 && have > size)
        {
            Local(() => File.Delete(part));
            have = 0;
        }
        if (size < 0 || have < size)
        {
            using var download = await client.DownloadAsync(item.Id, have, cancellation).ConfigureAwait(false);
            if (size < 0) size = download.Size;
            if (size < 0) throw new LocalFailure("the computer did not say how big it is.");
            // Without a Range answer the whole file comes again.
            if (download.Status == 200) have = 0;
            await using var output = Local(() => new FileStream(part, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous));
            var buffer = new byte[81920];
            while (true)
            {
                int read = await ReadWithinAsync(download.Body, buffer, cancellation).ConfigureAwait(false);
                if (read == 0) break;
                try
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    throw new LocalFailure(e.Message);
                }
                have += read;
            }
            if (have != size) throw new IOException("The download stopped early.");
        }
        string path = Local(() =>
        {
            string target = Path.Combine(directory, FileNames.Unique(directory, FileNames.Clean(item.Name)));
            File.Move(part, target);
            Inbox.MarkAsDownloaded(target);
            return target;
        });
        FileReceived?.Invoke(this, new ReceivedFile(host.Id, host.Name, path, size, null));
    }

    private static async Task<int> ReadWithinAsync(Stream body, byte[] buffer, CancellationToken cancellation)
    {
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        idle.CancelAfter(IdleTimeout);
        try
        {
            return await body.ReadAsync(buffer, idle.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new IOException("The download stalled.");
        }
    }

    private static T Local<T>(Func<T> step)
    {
        try
        {
            return step();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new LocalFailure(e.Message);
        }
    }

    private static void Local(Action step) => Local(() =>
    {
        step();
        return 0;
    });

    /// <summary>The item cannot be stored here (disk, folder, content), which waiting will not fix.</summary>
    private sealed class LocalFailure(string message) : Exception(message);
}
