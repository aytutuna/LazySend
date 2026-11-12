using System.Globalization;
using System.Text;

namespace LazySend.Core;

/// <summary>How far parsing a request's head got.</summary>
public enum HttpParseStatus
{
    /// <summary>The head has not fully arrived; read more.</summary>
    Incomplete,
    Complete,
    /// <summary>The request is refused; answer <see cref="HttpParseResult.ErrorStatus"/> and close.</summary>
    Invalid,
}

/// <summary>A request's line and headers.</summary>
/// <param name="Method">GET, PUT, POST or DELETE.</param>
/// <param name="Target">The request target as sent: the path and, after '?', the query.</param>
/// <param name="Headers">The headers in order, names as sent, values trimmed.</param>
/// <param name="ContentLength">The body's length; null when the request has no Content-Length.</param>
/// <param name="ExpectsContinue">The client sent <c>Expect: 100-continue</c> and waits before sending its body.</param>
public sealed record HttpRequestHead(string Method, string Target, IReadOnlyList<KeyValuePair<string, string>> Headers,
                                     long? ContentLength, bool ExpectsContinue)
{
    /// <summary>The target before any '?'.</summary>
    public string Path => Target.IndexOf('?') is int q and >= 0 ? Target[..q] : Target;

    /// <summary>The target after the first '?'; "" without one.</summary>
    public string Query => Target.IndexOf('?') is int q and >= 0 ? Target[(q + 1)..] : "";

    /// <summary>The first header named <paramref name="name"/> (case-insensitively); null when there is none.</summary>
    public string? Header(string name)
    {
        foreach (var header in Headers)
        {
            if (string.Equals(header.Key, name, StringComparison.OrdinalIgnoreCase)) return header.Value;
        }
        return null;
    }

    /// <summary>The token of an <c>Authorization: Bearer …</c> header; null without one.</summary>
    public string? BearerToken =>
        Header("Authorization") is { } value && value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? value[7..].Trim()
            : null;

    public bool Equals(HttpRequestHead? other) =>
        other is not null && Method == other.Method && Target == other.Target && Headers.SequenceEqual(other.Headers)
        && ContentLength == other.ContentLength && ExpectsContinue == other.ExpectsContinue;

    public override int GetHashCode() => HashCode.Combine(Method, Target, ContentLength);
}

/// <summary>The outcome of parsing a request's head.</summary>
/// <param name="Consumed">The bytes the head took, its blank line included (for <see cref="HttpParseStatus.Complete"/>).</param>
/// <param name="ErrorStatus">The status to answer with (for <see cref="HttpParseStatus.Invalid"/>).</param>
public readonly record struct HttpParseResult(HttpParseStatus Status, HttpRequestHead? Head = null, int Consumed = 0,
                                              int ErrorStatus = 0);

/// <summary>
/// The small part of HTTP/1.1 the phone link uses, read strictly: one request per connection
/// (the server always closes), a request line of GET, PUT, POST or DELETE with an origin-form target
/// and version HTTP/1.1, CRLF line ends only, no folded headers, at most
/// <see cref="MaxHeaderCount"/> headers in <see cref="MaxHeadBytes"/> bytes, a Host header, a body
/// only by one plain Content-Length (any Transfer-Encoding is refused, chunked included), and
/// <c>Expect: 100-continue</c> as the only expectation.
/// </summary>
public static class LinkHttp
{
    public const int MaxRequestLineBytes = 2048;
    public const int MaxHeadBytes = 16 * 1024;
    public const int MaxHeaderCount = 64;
    /// <summary>Content-Length digits read (a larger body is refused anyway).</summary>
    public const int MaxContentLengthDigits = 15;

    public static readonly IReadOnlyList<string> Methods = ["GET", "PUT", "POST", "DELETE"];

    /// <summary>Parses the head at the start of <paramref name="data"/>.</summary>
    public static HttpParseResult Parse(ReadOnlySpan<byte> data)
    {
        // Lines end in CRLF; a bare CR or LF is refused as soon as it is seen.
        int lineStart = 0;
        var lines = new List<string>();
        for (int i = 0; i < data.Length; i++)
        {
            byte b = data[i];
            if (b == (byte)'\n') return Invalid(400);
            if (b != (byte)'\r') continue;
            if (i + 1 >= data.Length) break;
            if (data[i + 1] != (byte)'\n') return Invalid(400);
            if (lines.Count == 0 && i - lineStart > MaxRequestLineBytes) return Invalid(414);
            if (i + 2 > MaxHeadBytes) return Invalid(431);
            if (i == lineStart)
            {
                if (lines.Count == 0) return Invalid(400);
                return Head(lines, i + 2);
            }
            if (lines.Count > MaxHeaderCount) return Invalid(431);
            lines.Add(Encoding.Latin1.GetString(data[lineStart..i]));
            lineStart = i + 2;
            i++;
        }
        if (lines.Count == 0 && data.Length - lineStart > MaxRequestLineBytes) return Invalid(414);
        if (data.Length >= MaxHeadBytes) return Invalid(431);
        return new HttpParseResult(HttpParseStatus.Incomplete);
    }

    /// <summary>The status line's reason phrase.</summary>
    public static string ReasonPhrase(int status) => status switch
    {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Content Too Large",
        414 => "URI Too Long",
        417 => "Expectation Failed",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        505 => "HTTP Version Not Supported",
        _ => "Unknown",
    };

    /// <summary>
    /// A response's head: the status line, <paramref name="headers"/> in order, then Content-Length
    /// and <c>Connection: close</c>, and the blank line.
    /// </summary>
    public static byte[] ResponseHead(int status, IEnumerable<KeyValuePair<string, string>> headers, long contentLength)
    {
        var text = new StringBuilder();
        text.Append("HTTP/1.1 ").Append(status.ToString(CultureInfo.InvariantCulture)).Append(' ')
            .Append(ReasonPhrase(status)).Append("\r\n");
        foreach (var header in headers) text.Append(header.Key).Append(": ").Append(header.Value).Append("\r\n");
        text.Append("Content-Length: ").Append(contentLength.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
        text.Append("Connection: close\r\n\r\n");
        return Encoding.ASCII.GetBytes(text.ToString());
    }

    /// <summary>The interim answer that lets a client waiting on <c>Expect: 100-continue</c> send its body.</summary>
    public static ReadOnlySpan<byte> ContinueResponse => "HTTP/1.1 100 Continue\r\n\r\n"u8;

    /// <summary>A query's parameters (first value of each name kept); names and values as sent, not decoded.</summary>
    public static IReadOnlyDictionary<string, string> QueryParameters(string query)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string part in query.Split('&'))
        {
            if (part.Length == 0) continue;
            int equals = part.IndexOf('=');
            values.TryAdd(equals < 0 ? part : part[..equals], equals < 0 ? "" : part[(equals + 1)..]);
        }
        return values;
    }

    private static HttpParseResult Invalid(int status) => new(HttpParseStatus.Invalid, ErrorStatus: status);

    private static HttpParseResult Head(List<string> lines, int consumed)
    {
        string[] parts = lines[0].Split(' ');
        if (parts.Length != 3) return Invalid(400);
        string method = parts[0], target = parts[1], version = parts[2];
        if (method.Length == 0 || !method.All(IsTokenChar)) return Invalid(400);
        if (!Methods.Contains(method)) return Invalid(501);
        if (version != "HTTP/1.1")
        {
            return version.StartsWith("HTTP/", StringComparison.Ordinal) && version.Length == 8
                   && char.IsAsciiDigit(version[5]) && version[6] == '.' && char.IsAsciiDigit(version[7])
                ? Invalid(505)
                : Invalid(400);
        }
        if (target.Length == 0 || target[0] != '/' || target.Any(c => c is <= ' ' or >= (char)0x7F or '#'))
        {
            return Invalid(400);
        }

        var headers = new List<KeyValuePair<string, string>>(lines.Count - 1);
        long? contentLength = null;
        bool expectsContinue = false, hasHost = false;
        foreach (string line in lines.Skip(1))
        {
            if (line[0] is ' ' or '\t') return Invalid(400);
            int colon = line.IndexOf(':');
            if (colon <= 0) return Invalid(400);
            string name = line[..colon];
            if (!name.All(IsTokenChar)) return Invalid(400);
            string value = line[(colon + 1)..].Trim(' ', '\t');
            if (value.Any(c => c != '\t' && (c < ' ' || c >= (char)0x7F))) return Invalid(400);
            headers.Add(new KeyValuePair<string, string>(name, value));
            if (Is(name, "Content-Length"))
            {
                if (contentLength is not null || value.Length == 0 || value.Length > MaxContentLengthDigits
                    || !value.All(char.IsAsciiDigit))
                {
                    return Invalid(400);
                }
                contentLength = long.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
            }
            else if (Is(name, "Transfer-Encoding"))
            {
                return Invalid(501);
            }
            else if (Is(name, "Host"))
            {
                if (hasHost) return Invalid(400);
                hasHost = true;
            }
            else if (Is(name, "Expect"))
            {
                if (!Is(value, "100-continue")) return Invalid(417);
                expectsContinue = true;
            }
        }
        if (!hasHost) return Invalid(400);
        return new HttpParseResult(HttpParseStatus.Complete,
                                   new HttpRequestHead(method, target, headers, contentLength, expectsContinue), consumed);
    }

    private static bool Is(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>A tchar of RFC 9110: letters, digits and <c>!#$%&amp;'*+-.^_`|~</c>.</summary>
    private static bool IsTokenChar(char c) =>
        c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9'
            or '!' or '#' or '$' or '%' or '&' or '\'' or '*' or '+' or '-' or '.' or '^' or '_' or '`' or '|' or '~';
}
