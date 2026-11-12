using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;

namespace LazySend.Core;

/// <summary>A refusal the router answers with <see cref="Status"/> and <see cref="Error"/>.</summary>
public sealed class InboxException(int status, LinkError error) : Exception(error.Message)
{
    public int Status { get; } = status;
    public LinkError Error { get; } = error;
}

/// <summary>A file that arrived whole.</summary>
public sealed record ReceivedFile(string DeviceId, string DeviceName, string Path, long Size, string? SourceId);

/// <summary>A file being received (or finished a while ago), kept in a small JSON file next to its data so a restart can go on.</summary>
public sealed class IncomingFile
{
    public string Id { get; set; } = "";
    public string DeviceId { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public string Name { get; set; } = "";
    public long Size { get; set; }
    public string? Mime { get; set; }
    public DateTimeOffset? Modified { get; set; }
    public string? SourceId { get; set; }
    public string? Sha256 { get; set; }
    /// <summary>The folder the file ends up in; fixed when the transfer starts, so changing the receive folder later strands nothing.</summary>
    public string Directory { get; set; } = "";
    public DateTimeOffset Started { get; set; }
    public bool Done { get; set; }
    /// <summary>The file's path once done.</summary>
    public string? Path { get; set; }
    public DateTimeOffset? Finished { get; set; }
}

/// <summary>
/// Files from phones: begun with the item's metadata, filled in chunks into <c>&lt;id&gt;.part</c> in the
/// folder they will end up in, and renamed into place when the last byte is in and the SHA-256, when
/// given, matches. The offset a phone resumes from is the length of the part file, so what was written
/// before a dropped connection or a restart counts. One chunk is written at a time per file: a newer
/// request takes over from one that is still open (the phone has already given up on that connection).
/// </summary>
public sealed class Inbox
{
    public static readonly TimeSpan PartKept = TimeSpan.FromDays(7);
    public static readonly TimeSpan DoneKept = TimeSpan.FromDays(1);
    private static readonly TimeSpan TakeOverWait = TimeSpan.FromSeconds(5);

    private readonly string _directory;
    private readonly Func<string> _receiveRoot;
    private readonly GalleryIndex _index;
    private readonly Func<string, long> _freeSpace;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();
    private readonly Dictionary<string, IncomingFile> _files = [];
    /// <summary>The unfinished file of each (phone, source id), so a gallery sync of tens of thousands of photos does not scan every record.</summary>
    private readonly Dictionary<(string Device, string Source), IncomingFile> _bySource = [];
    private DateTimeOffset _lastPrune;
    private readonly ConcurrentDictionary<string, Writer> _writers = new();

    /// <param name="directory">Where the transfers' small state files go (<see cref="SendPaths.IncomingDirectory"/>).</param>
    /// <param name="receiveRoot">The folder files go under, asked for when a transfer starts.</param>
    /// <param name="freeSpace">Free bytes on the drive of a path; the drive's own figure when null.</param>
    public Inbox(string directory, Func<string> receiveRoot, GalleryIndex index, Func<string, long>? freeSpace = null,
                 Func<DateTimeOffset>? clock = null)
    {
        _directory = directory;
        _receiveRoot = receiveRoot;
        _index = index;
        _freeSpace = freeSpace ?? FreeBytes;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Load();
    }

    /// <summary>A file arrived whole (on the request's thread).</summary>
    public event EventHandler<ReceivedFile>? FileReceived;

    /// <summary>Everything a phone is sending that is not finished.</summary>
    public IReadOnlyList<IncomingFile> InProgress
    {
        get
        {
            lock (_gate) return [.. _files.Values.Where(f => !f.Done)];
        }
    }

    /// <summary>
    /// Starts a file, or finds the one already started for the same source id. A source id that was
    /// received before answers done. Throws <see cref="InboxException"/>.
    /// </summary>
    public ItemState Begin(PairedDevice device, ItemRequest request)
    {
        if (request.Size is not { } size || size < 0) throw new InboxException(400, LinkError.BadRequest);
        if (request.SourceId is not null && !GalleryIndex.IsValidSourceId(request.SourceId)) throw new InboxException(400, LinkError.BadRequest);
        string? sha256 = null;
        if (request.Sha256 is not null)
        {
            if (request.Sha256.Length != 64 || !request.Sha256.All(Uri.IsHexDigit)) throw new InboxException(400, LinkError.BadRequest);
            sha256 = request.Sha256.ToLowerInvariant();
        }
        if (request.SourceId is { } source && _index.Contains(device.Id, source)) return new ItemState("", size, true, Duplicate: true);

        var now = _clock();
        PruneIfDue(now);
        // A phone can send any date; only plausible ones are kept (a file time outside this range cannot be set).
        DateTimeOffset? modified = request.Modified is { Year: >= 1980 and <= 2100 } m ? m : null;
        string folder = Path.Combine(_receiveRoot(), FileNames.Clean(device.Name, "Phone"));
        if (request.SourceId is not null) folder = Path.Combine(folder, "Gallery", (modified ?? now).ToLocalTime().ToString("yyyy-MM", CultureInfo.InvariantCulture));
        if (_freeSpace(folder) - size < Protocol.MinFreeBytes) throw new InboxException(507, LinkError.DiskFull);
        var file = new IncomingFile
        {
            Id = Protocol.NewId(),
            DeviceId = device.Id,
            DeviceName = device.Name,
            Name = FileNames.Clean(request.Name),
            Size = size,
            Mime = request.Mime,
            Modified = modified,
            SourceId = request.SourceId,
            Sha256 = sha256,
            Directory = folder,
            Started = now,
        };
        // Looked up and added in one step, so two requests for the same asset cannot start two transfers.
        IncomingFile? existing = null;
        lock (_gate)
        {
            if (request.SourceId is { } asset)
            {
                if (_bySource.TryGetValue((device.Id, asset), out var known) && !known.Done && known.Size == size) existing = known;
            }
            if (existing is null) Track(file);
        }
        if (existing is not null)
        {
            FinishIfFull(existing);
            return StateOf(existing);
        }
        try
        {
            Directory.CreateDirectory(folder);
            using (File.Create(PartPath(file))) { }
            Save(file);
            if (size == 0) Complete(file, null);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Discard(file);
            throw Failed(e);
        }
        return StateOf(file);
    }

    /// <summary>Where a file of <paramref name="deviceId"/> stands; null when there is no such file.</summary>
    public ItemState? State(string deviceId, string id)
    {
        IncomingFile? file;
        lock (_gate) _files.TryGetValue(id, out file);
        if (file is null || file.DeviceId != deviceId) return null;
        FinishIfFull(file);
        lock (_gate) return _files.ContainsKey(id) ? StateOf(file) : null;
    }

    /// <summary>
    /// Writes <paramref name="length"/> bytes of <paramref name="body"/> at <paramref name="offset"/>.
    /// Returns the new state; done once the last byte is in. Throws <see cref="InboxException"/> and,
    /// when the connection breaks, <see cref="IOException"/> or <see cref="OperationCanceledException"/>
    /// after keeping what arrived.
    /// </summary>
    public async Task<ItemState> WriteAsync(string deviceId, string id, long offset, long length, Stream body, CancellationToken cancellation)
    {
        IncomingFile? file;
        lock (_gate) _files.TryGetValue(id, out file);
        if (file is null || file.DeviceId != deviceId) throw new InboxException(404, LinkError.NotFound);
        if (file.Done)
        {
            // The last chunk got through but its answer did not.
            await DiscardAsync(body, length, cancellation).ConfigureAwait(false);
            return StateOf(file);
        }
        if (length < 0 || (length == 0 && offset != file.Size) || offset < 0 || offset > file.Size || length > file.Size - offset) throw new InboxException(400, LinkError.BadRequest);
        if (length > Protocol.MaxChunkBytes) throw new InboxException(413, LinkError.TooLarge);
        if (_freeSpace(file.Directory) - length < Protocol.MinFreeBytes) throw new InboxException(507, LinkError.DiskFull);

        var writer = _writers.GetOrAdd(id, _ => new Writer());
        using var takeOver = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        if (!writer.Gate.Wait(0))
        {
            CancelActive(writer);
            if (!await writer.Gate.WaitAsync(TakeOverWait, cancellation).ConfigureAwait(false)) throw new InboxException(409, LinkError.Busy);
        }
        writer.Active = takeOver;
        try
        {
            // The record may have been discarded while this request waited for the gate.
            lock (_gate)
            {
                if (!_files.ContainsKey(id)) throw new InboxException(404, LinkError.NotFound);
            }
            if (file.Done) return StateOf(file);
            if (length == 0)
            {
                // A part that is full but never got through Complete: finish it.
                long current = PartLength(file);
                if (current != file.Size) throw new InboxException(409, LinkError.OffsetMismatch(current));
                Complete(file, writer);
                return StateOf(file);
            }
            long end;
            try
            {
                await using var stream = OpenPart(file);
                if (stream.Length != offset)
                {
                    await DiscardAsync(body, length, takeOver.Token).ConfigureAwait(false);
                    throw new InboxException(409, LinkError.OffsetMismatch(stream.Length));
                }
                if (offset == 0)
                {
                    writer.Hashed = 0;
                    writer.Hash = file.Sha256 is null ? null : IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                }
                else if (writer.Hashed != offset)
                {
                    writer.Hash = null;
                }
                stream.Seek(offset, SeekOrigin.Begin);
                var buffer = new byte[256 * 1024];
                long left = length;
                try
                {
                    while (left > 0)
                    {
                        int read = await body.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, left)), takeOver.Token).ConfigureAwait(false);
                        if (read == 0) throw new EndOfStreamException("The connection ended before the chunk did.");
                        await WritePartAsync(stream, buffer.AsMemory(0, read)).ConfigureAwait(false);
                        writer.Hash?.AppendData(buffer.AsSpan(0, read));
                        writer.Hashed += read;
                        left -= read;
                    }
                }
                finally
                {
                    await stream.FlushAsync(CancellationToken.None).ConfigureAwait(false);
                }
                end = stream.Length;
            }
            catch (UnauthorizedAccessException e)
            {
                throw Failed(e);
            }
            if (end < file.Size) return StateOf(file, end);
            Complete(file, writer);
            return StateOf(file);
        }
        finally
        {
            writer.Active = null;
            writer.Gate.Release();
        }
    }

    /// <summary>Drops what a phone had begun and not finished, and the records of what it finished (it was removed). Received files stay.</summary>
    public void RemoveDevice(string deviceId)
    {
        IncomingFile[] files;
        lock (_gate) files = [.. _files.Values.Where(f => f.DeviceId == deviceId)];
        foreach (var file in files)
        {
            // A chunk still coming in is stopped first, so its part can be deleted.
            var writer = _writers.GetOrAdd(file.Id, _ => new Writer());
            CancelActive(writer);
            bool held = writer.Gate.Wait(TakeOverWait);
            try
            {
                Discard(file);
            }
            finally
            {
                if (held) writer.Gate.Release();
            }
        }
    }

    /// <summary>
    /// Finishes a file whose part is already full but never got through <see cref="Complete"/> (it threw,
    /// or the process ended first). Skipped while a chunk is being written.
    /// </summary>
    private void FinishIfFull(IncomingFile file)
    {
        if (file.Done || PartLength(file) != file.Size) return;
        var writer = _writers.GetOrAdd(file.Id, _ => new Writer());
        if (!writer.Gate.Wait(0)) return;
        try
        {
            if (!file.Done) Complete(file, writer);
        }
        catch (InboxException)
        {
            // Answered by the next request; a hash mismatch has removed the file.
        }
        finally
        {
            writer.Gate.Release();
        }
    }

    private void Complete(IncomingFile file, Writer? writer)
    {
        string part = PartPath(file);
        string path;
        lock (_gate)
        {
            if (!_files.ContainsKey(file.Id)) throw new InboxException(404, LinkError.NotFound);
        }
        try
        {
            if (file.Sha256 is { } expected)
            {
                string actual = writer is { Hash: { } hash } && writer.Hashed == file.Size
                    ? Convert.ToHexStringLower(hash.GetHashAndReset())
                    : HashFile(part);
                if (actual != expected)
                {
                    Discard(file);
                    throw new InboxException(422, LinkError.HashMismatch);
                }
            }
            path = MoveIntoPlace(file, part);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw Failed(e);
        }
        // The file is in place: record that first, so nothing below can make the phone send it again.
        file.Done = true;
        file.Path = path;
        file.Finished = _clock();
        bool removed;
        lock (_gate)
        {
            removed = !_files.ContainsKey(file.Id);
            Untrack(file);
        }
        // The phone was removed while the file was finishing: the file stays, nothing is announced or recorded.
        if (removed) return;
        BestEffort(() => Save(file));
        BestEffort(() => MarkAsDownloaded(path));
        if (file.Modified is { } modified) BestEffort(() => File.SetLastWriteTimeUtc(path, modified.UtcDateTime));
        if (file.SourceId is { } source) BestEffort(() => _index.Add(file.DeviceId, source));
        writer?.Hash?.Dispose();
        _writers.TryRemove(file.Id, out _);
        FileReceived?.Invoke(this, new ReceivedFile(file.DeviceId, file.DeviceName, path, file.Size, file.SourceId));
    }

    /// <summary>Tags the file as coming from the internet zone, so SmartScreen and Office checks apply to what a phone sends (.exe, .lnk, .url…).</summary>
    private static void MarkAsDownloaded(string path)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
        }
        catch (NotSupportedException)
        {
            // A file system without alternate streams.
        }
    }

    private static void BestEffort(Action step)
    {
        try
        {
            step();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            System.Diagnostics.Trace.TraceWarning($"A step after receiving a file failed: {e.Message}");
        }
    }

    private static string MoveIntoPlace(IncomingFile file, string part)
    {
        // Another file may take the name between the check and the move, and a virus scanner
        // may hold the part file for a moment.
        for (int attempt = 0; ; attempt++)
        {
            string path = Path.Combine(file.Directory, FileNames.Unique(file.Directory, file.Name));
            try
            {
                File.Move(part, path);
                return path;
            }
            catch (IOException) when (attempt < 20)
            {
                if (!File.Exists(path)) Thread.Sleep(100);
            }
        }
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    private void Discard(IncomingFile file)
    {
        // A part that cannot be deleted keeps its record, so a later cleanup finds it again.
        if (!TryDelete(PartPath(file))) return;
        Forget(file);
        _writers.TryRemove(file.Id, out _);
        TryDelete(MetaPath(file.Id));
    }

    private void Track(IncomingFile file)
    {
        lock (_gate)
        {
            _files[file.Id] = file;
            if (!file.Done && file.SourceId is { } source) _bySource[(file.DeviceId, source)] = file;
        }
    }

    private void Forget(IncomingFile file)
    {
        lock (_gate)
        {
            _files.Remove(file.Id);
            Untrack(file);
        }
    }

    // With the gate held.
    private void Untrack(IncomingFile file)
    {
        if (file.SourceId is { } source && _bySource.TryGetValue((file.DeviceId, source), out var current) && ReferenceEquals(current, file))
        {
            _bySource.Remove((file.DeviceId, source));
        }
    }

    private static bool IsStale(IncomingFile file, DateTimeOffset now) =>
        file.Done ? now - (file.Finished ?? file.Started) > DoneKept : now - LastActivity(file) > PartKept;

    /// <summary>Drops finished records older than a day and parts nobody has touched for a week; at most once an hour.</summary>
    private void PruneIfDue(DateTimeOffset now)
    {
        IncomingFile[] stale;
        lock (_gate)
        {
            if (now - _lastPrune < TimeSpan.FromHours(1)) return;
            _lastPrune = now;
            stale = [.. _files.Values.Where(f => IsStale(f, now))];
        }
        foreach (var file in stale)
        {
            var writer = _writers.GetOrAdd(file.Id, _ => new Writer());
            if (!writer.Gate.Wait(0)) continue;
            try
            {
                Discard(file);
            }
            finally
            {
                writer.Gate.Release();
            }
        }
    }

    private static ItemState StateOf(IncomingFile file, long? offset = null)
    {
        if (file.Done) return new ItemState(file.Id, file.Size, true);
        long length = offset ?? PartLength(file);
        return new ItemState(file.Id, length, false);
    }

    private static long PartLength(IncomingFile file)
    {
        try
        {
            // FileInfo can report a stale size while a chunk is being written.
            using var handle = File.OpenHandle(PartPath(file), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return RandomAccess.GetLength(handle);
        }
        catch (IOException)
        {
            return 0;
        }
    }

    private static string PartPath(IncomingFile file) => Path.Combine(file.Directory, file.Id + ".part");

    private static void CancelActive(Writer writer)
    {
        try
        {
            writer.Active?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The request that held it has just ended.
        }
    }

    private FileStream OpenPart(IncomingFile file)
    {
        try
        {
            return new FileStream(PartPath(file), FileMode.Open, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            // Someone removed the part: the record is no use, the phone starts the file again.
            Discard(file);
            throw new InboxException(404, LinkError.NotFound);
        }
        catch (IOException e)
        {
            throw Failed(e);
        }
    }

    // A failed disk write is the computer's fault and is answered; a failed read of the request ends the connection.
    private static async Task WritePartAsync(FileStream stream, ReadOnlyMemory<byte> data)
    {
        try
        {
            await stream.WriteAsync(data, CancellationToken.None).ConfigureAwait(false);
        }
        catch (IOException e)
        {
            throw Failed(e);
        }
    }

    private string MetaPath(string id) => Path.Combine(_directory, id + ".json");

    private void Save(IncomingFile file) => JsonFile.Save(MetaPath(file.Id), file);

    private static InboxException Failed(Exception e)
    {
        System.Diagnostics.Trace.TraceWarning($"Could not store a file from a phone: {e.Message}");
        return new InboxException(500, LinkError.ServerError);
    }

    private static async Task DiscardAsync(Stream body, long length, CancellationToken cancellation)
    {
        // A body the client holds back (Expect: 100-continue) is never sent, so there is nothing to read.
        if (body is LinkRequestBody { IsWithheld: true }) return;
        var buffer = new byte[81920];
        while (length > 0)
        {
            int read = await body.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, length)), cancellation).ConfigureAwait(false);
            if (read == 0) return;
            length -= read;
        }
    }

    private void Load()
    {
        if (!Directory.Exists(_directory)) return;
        var now = _clock();
        _lastPrune = now;
        foreach (string path in Directory.EnumerateFiles(_directory, "*.json"))
        {
            var file = JsonFile.Load<IncomingFile>(path);
            if (!Protocol.IsValidId(file.Id) || file.Directory.Length == 0)
            {
                TryDelete(path);
                continue;
            }
            bool stale = IsStale(file, now);
            Track(file);
            if (stale) Discard(file);
            else FinishIfFull(file);
        }
    }

    private static DateTimeOffset LastActivity(IncomingFile file)
    {
        var written = File.GetLastWriteTimeUtc(PartPath(file));
        return written.Year > 1700 ? new DateTimeOffset(written) : file.Started;
    }

    private static bool TryDelete(string path)
    {
        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left for the next cleanup.
            return false;
        }
    }

    private static long FreeBytes(string path)
    {
        try
        {
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!).AvailableFreeSpace;
        }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException)
        {
            // A network share has no drive figure; the write itself fails when it is full.
            return long.MaxValue;
        }
    }

    private sealed class Writer
    {
        public readonly SemaphoreSlim Gate = new(1, 1);
        public CancellationTokenSource? Active;
        public IncrementalHash? Hash;
        public long Hashed;
    }
}
