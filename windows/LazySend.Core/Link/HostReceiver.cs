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
    private const int FinishedKept = 200;

    private readonly object _gate = new();
    private readonly Queue<string> _finishedOrder = new();
    private readonly HashSet<string> _finished = [];
    private bool _storageReported;

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
            foreach (var item in reply.Items ?? [])
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
                    if (WasFinished(host.Id, item.Id)) break;
                    await DownloadAsync(host, client, item, cancellation).ConfigureAwait(false);
                    RememberFinished(host.Id, item.Id);
                    break;
            }
        }
        catch (LinkException e) when (!LeavesQueued(e))
        {
            DropPart(host, item);
            Failed?.Invoke(this, $"{item.Name ?? "An item"} from {host.Name} could not be received: {e.Message}");
        }
        catch (LocalFailure e)
        {
            DropPart(host, item);
            Failed?.Invoke(this, $"{item.Name ?? "An item"} from {host.Name} could not be saved: {e.Message}");
        }
        await client.AcknowledgeAsync(item.Id, cancellation).ConfigureAwait(false);
    }

    private bool WasFinished(string hostId, string itemId)
    {
        lock (_gate) return _finished.Contains(hostId + "/" + itemId);
    }

    /// <summary>A file whose acknowledgement is lost is listed again; remembering the lately finished ones lets it be only acknowledged.</summary>
    private void RememberFinished(string hostId, string itemId)
    {
        lock (_gate)
        {
            string key = hostId + "/" + itemId;
            if (!_finished.Add(key)) return;
            _finishedOrder.Enqueue(key);
            while (_finishedOrder.Count > FinishedKept) _finished.Remove(_finishedOrder.Dequeue());
        }
    }

    private string DirectoryOf(GuestHost host) => Path.Combine(settings.ReceiveRoot, FileNames.Clean(host.Name, "Computer"));

    /// <summary>What an item that is dropped from the host's queue leaves half-downloaded is of no use.</summary>
    private void DropPart(GuestHost host, OutboxEntry item)
    {
        try
        {
            File.Delete(Path.Combine(DirectoryOf(host), item.Id + ".part"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete a part file: {e.Message}");
        }
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
        string directory = DirectoryOf(host);
        string part = Path.Combine(directory, item.Id + ".part");
        long size = item.Size ?? -1;
        long have = Storage(() =>
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
            await using var output = Storage(() => new FileStream(part, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous));
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
            // An empty file was never downloaded, so there is no part yet.
            if (!File.Exists(part)) File.WriteAllBytes(part, []);
            File.Move(part, target);
            return target;
        });
        try
        {
            Inbox.MarkAsDownloaded(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not mark a received file as downloaded: {e.Message}");
        }
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

    /// <summary>
    /// The receive folder or the part file cannot be used (missing, denied, on a drive that is not there). That says nothing
    /// about the item, so it stays queued on the host and is asked for again later; the user is told once until it works.
    /// </summary>
    private T Storage<T>(Func<T> step)
    {
        try
        {
            T result = step();
            _storageReported = false;
            return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            if (!_storageReported)
            {
                _storageReported = true;
                Failed?.Invoke(this, $"Files cannot be saved in the receive folder ({e.Message}). They stay queued on the other computer until it works.");
            }
            throw new IOException(e.Message, e);
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
