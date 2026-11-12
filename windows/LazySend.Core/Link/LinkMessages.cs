using System.Net;
using System.Text;

namespace LazySend.Core;

public sealed class LinkRequestBody : Stream
{
    private readonly Stream _source;
    private readonly ReadOnlyMemory<byte> _prefix;
    private readonly Func<CancellationToken, Task>? _sendContinue;
    private int _prefixUsed;
    private long _remaining;

    /// <param name="source">The connection after the head (or the whole body in tests).</param>
    /// <param name="length">The body's length (Content-Length; 0 without one).</param>
    /// <param name="prefix">Bytes of the body that arrived with the head.</param>
    /// <param name="sendContinue">Sends "100 Continue"; null when the client did not ask for it.</param>
    public LinkRequestBody(Stream source, long length, ReadOnlyMemory<byte> prefix = default,
                                Func<CancellationToken, Task>? sendContinue = null)
    {
        _source = source;
        _remaining = length;
        _prefix = prefix.Length > length ? prefix[..(int)length] : prefix;
        _sendContinue = sendContinue;
        BodyLength = length;
    }

    /// <summary>The body's length.</summary>
    public long BodyLength { get; }

    /// <summary>The bytes not read yet.</summary>
    public long Remaining => _remaining;

    /// <summary>Reading began (and "100 Continue" was sent when asked for).</summary>
    public bool HasStarted { get; private set; }

    /// <summary>The client still holds its body back: it asked to wait and was not told to send it.</summary>
    public bool IsWithheld => _sendContinue is not null && !HasStarted && _remaining > 0;

    /// <summary>
    /// Reads and drops the rest of the body when it is at most <paramref name="maxBytes"/>, so the
    /// connection can be closed without cutting the client off mid-send; a withheld body needs no
    /// reading. Returns whether nothing is left unread.
    /// </summary>
    public async Task<bool> DiscardAsync(long maxBytes, CancellationToken cancellation)
    {
        if (IsWithheld || _remaining == 0) return true;
        if (_remaining > maxBytes) return false;
        var buffer = new byte[81920];
        while (_remaining > 0)
        {
            if (await ReadAsync(buffer, cancellation).ConfigureAwait(false) == 0) return false;
        }
        return true;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (_remaining <= 0 || buffer.Length == 0) return 0;
        if (!HasStarted)
        {
            HasStarted = true;
            if (_sendContinue is not null) await _sendContinue(cancellationToken).ConfigureAwait(false);
        }
        int count;
        if (_prefixUsed < _prefix.Length)
        {
            count = Math.Min(buffer.Length, _prefix.Length - _prefixUsed);
            _prefix.Slice(_prefixUsed, count).CopyTo(buffer);
            _prefixUsed += count;
        }
        else
        {
            count = await _source.ReadAsync(buffer[..(int)Math.Min(buffer.Length, _remaining)], cancellationToken).ConfigureAwait(false);
            if (count == 0) return 0;
        }
        _remaining -= count;
        return count;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => BodyLength;

    public override long Position
    {
        get => BodyLength - _remaining;
        set => throw new NotSupportedException();
    }

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

/// <summary>One request to the phone link server: its head, its body and where it came from.</summary>
public sealed record LinkRequest(HttpRequestHead Head, LinkRequestBody Body, IPAddress Remote);

/// <summary>A response: its status, headers and a body held in memory or streamed from a file.</summary>
public sealed class LinkResponse
{
    private LinkResponse(int status, IReadOnlyList<KeyValuePair<string, string>> headers, byte[] body, Stream? stream = null,
                         long streamLength = 0)
    {
        Status = status;
        Headers = headers;
        Body = body;
        Stream = stream;
        ContentLength = stream is null ? body.Length : streamLength;
    }

    public int Status { get; }
    /// <summary>Headers besides Content-Length and Connection, which the server adds.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers { get; }
    public byte[] Body { get; }
    /// <summary>The body when it is read from a stream (a download); the server copies <see cref="ContentLength"/> bytes and disposes it.</summary>
    public Stream? Stream { get; }
    public long ContentLength { get; }

    /// <summary>Called once by the server with whether the response was written to the client.</summary>
    public Action<bool>? Written { get; set; }

    public static LinkResponse Json(int status, string json, params KeyValuePair<string, string>[] headers) =>
        new(status, [new("Content-Type", Protocol.JsonContentType), .. headers], Encoding.UTF8.GetBytes(json));

    public static LinkResponse Json<T>(int status, T value, params KeyValuePair<string, string>[] headers) =>
        Json(status, Protocol.ToJson(value), headers);

    public static LinkResponse Error(int status, LinkError error, params KeyValuePair<string, string>[] headers) =>
        Json(status, error.ToJson(), headers);

    public static LinkResponse Empty(int status, params KeyValuePair<string, string>[] headers) => new(status, headers, []);

    public static LinkResponse FromStream(int status, Stream stream, long length, params KeyValuePair<string, string>[] headers) =>
        new(status, headers, [], stream, length);

    /// <summary>The body as text (tests).</summary>
    public string Text => Encoding.UTF8.GetString(Body);
}
