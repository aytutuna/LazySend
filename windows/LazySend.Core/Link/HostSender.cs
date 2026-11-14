using System.Security.Cryptography;

namespace LazySend.Core;

/// <summary>
/// Sends to one host: text, links and files, a file in chunks that carry on after drops. After a drop it asks
/// the host where the file stands and continues from the offset it is told, never from what it sent. One
/// instance per send; <paramref name="connect"/> finds the host again after a failure.
/// </summary>
public sealed class HostSender(Func<CancellationToken, Task<LinkClient>> connect, IReadOnlyList<TimeSpan>? retryDelays = null) : IDisposable
{
    public const int ChunkBytes = 4 * 1024 * 1024;

    private static readonly TimeSpan[] DefaultDelays =
        [.. new[] { 1, 2, 4, 8, 15, 30, 30, 30 }.Select(seconds => TimeSpan.FromSeconds(seconds))];

    private readonly IReadOnlyList<TimeSpan> _delays = retryDelays ?? DefaultDelays;
    private LinkClient? _client;

    public Task SendTextAsync(string text, CancellationToken cancellation) =>
        RetryAsync(c => c.PostItemAsync(new ItemRequest(ItemKind.Text, Text: text), cancellation), cancellation);

    public Task SendLinkAsync(string url, CancellationToken cancellation) =>
        RetryAsync(c => c.PostItemAsync(new ItemRequest(ItemKind.Link, Url: url), cancellation), cancellation);

    /// <summary>What the host is told about the file at <paramref name="path"/>: its name, size, modified time and SHA-256.</summary>
    public static ItemRequest FileRequest(string path)
    {
        var info = new FileInfo(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return new ItemRequest(ItemKind.File, Name: info.Name, Size: stream.Length, Modified: info.LastWriteTimeUtc,
                               Sha256: Convert.ToHexStringLower(SHA256.HashData(stream)));
    }

    public Task SendFileAsync(string path, IProgress<long>? progress, CancellationToken cancellation) =>
        SendFileAsync(FileRequest(path), path, progress, cancellation);

    /// <summary>Sends the file as <paramref name="request"/> describes it; <paramref name="progress"/> gets the bytes the host is known to have.</summary>
    public async Task SendFileAsync(ItemRequest request, string path, IProgress<long>? progress, CancellationToken cancellation)
    {
        long size = request.Size ?? throw new ArgumentException("A file needs a size.", nameof(request));
        var state = await RetryAsync(c => c.PostItemAsync(request, cancellation), cancellation).ConfigureAwait(false);
        if (state.Duplicate == true) return;
        progress?.Report(state.Offset);
        bool restarted = false;
        var buffer = new byte[ChunkBytes];
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.Asynchronous);
        while (!state.Done)
        {
            int length = (int)Math.Min(ChunkBytes, size - state.Offset);
            file.Seek(state.Offset, SeekOrigin.Begin);
            await file.ReadExactlyAsync(buffer.AsMemory(0, length), cancellation).ConfigureAwait(false);
            try
            {
                state = await PutAsync(state, buffer.AsMemory(0, length), cancellation).ConfigureAwait(false);
            }
            catch (LinkException e) when (e.Code == ErrorCode.OffsetMismatch && e.Offset is { } offset && offset >= 0 && offset <= size)
            {
                state = state with { Offset = offset };
            }
            catch (LinkException e) when (e.Code is ErrorCode.HashMismatch or ErrorCode.NotFound && !restarted)
            {
                restarted = true;
                state = await RetryAsync(c => c.PostItemAsync(request, cancellation), cancellation).ConfigureAwait(false);
            }
            progress?.Report(state.Offset);
        }
    }

    private async Task<ItemState> PutAsync(ItemState state, ReadOnlyMemory<byte> data, CancellationToken cancellation)
    {
        for (int failures = 0; ; failures++)
        {
            try
            {
                _client ??= await connect(cancellation).ConfigureAwait(false);
                return await _client.PutChunkAsync(state.Id, state.Offset, data, cancellation).ConfigureAwait(false);
            }
            catch (Exception e) when (IsTransient(e) && failures < _delays.Count)
            {
                await ReconnectAfterAsync(failures, cancellation).ConfigureAwait(false);
            }
            // The chunk may have landed before the answer was lost, so ask before it goes again.
            try
            {
                _client ??= await connect(cancellation).ConfigureAwait(false);
                return await _client.ItemStateAsync(state.Id, cancellation).ConfigureAwait(false);
            }
            catch (Exception e) when (IsTransient(e))
            {
            }
        }
    }

    private async Task<T> RetryAsync<T>(Func<LinkClient, Task<T>> call, CancellationToken cancellation)
    {
        for (int failures = 0; ; failures++)
        {
            try
            {
                _client ??= await connect(cancellation).ConfigureAwait(false);
                return await call(_client).ConfigureAwait(false);
            }
            catch (Exception e) when (IsTransient(e) && failures < _delays.Count)
            {
                await ReconnectAfterAsync(failures, cancellation).ConfigureAwait(false);
            }
        }
    }

    private static bool IsTransient(Exception e) => e is IOException || e is LinkException { IsBusy: true };

    private async Task ReconnectAfterAsync(int failures, CancellationToken cancellation)
    {
        _client?.Dispose();
        _client = null;
        await Task.Delay(_delays[failures], cancellation).ConfigureAwait(false);
    }

    public void Dispose() => _client?.Dispose();
}
