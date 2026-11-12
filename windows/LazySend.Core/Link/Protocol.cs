using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LazySend.Core;

/// <summary>
/// The link between a paired phone and the desktop: HTTP/1.1 over TLS, the phone always opening the
/// connection. The routes and their bodies are in CONTRACTS.md; this holds the constants, the
/// message types and the error codes.
/// </summary>
public static class Protocol
{
    public const int Version = 1;
    public const string ServiceType = "_lazysend._tcp";
    public const string ServiceName = "lazysend";
    public const int DefaultPort = 52734;

    public const string HealthPath = "/v1/health";
    public const string PairPath = "/v1/pair";
    public const string HelloPath = "/v1/hello";
    public const string DeviceSelfPath = "/v1/devices/self";
    public const string ItemsPath = "/v1/items";
    public const string ItemsPrefix = "/v1/items/";
    public const string GalleryCheckPath = "/v1/gallery/check";
    public const string OutboxPath = "/v1/outbox";
    public const string OutboxPrefix = "/v1/outbox/";

    public const string DeviceIdHeader = "X-Device-Id";
    public const string OffsetHeader = "X-Offset";
    public const string JsonContentType = "application/json; charset=utf-8";

    public const string TxtVersionKey = "v";
    public const string TxtIdKey = "id";

    /// <summary>A pairing request, small enough to be read under a total time limit.</summary>
    public const int MaxSmallBodyBytes = 8192;
    /// <summary>Metadata of an item; room for 1 MiB of text with every character escaped.</summary>
    public const int MaxItemBodyBytes = 8 * 1024 * 1024;
    public const int MaxTextBytes = 1024 * 1024;
    public const int MaxUrlLength = 8192;
    public const int MaxGalleryCheckBodyBytes = 512 * 1024;
    public const int MaxGalleryCheckIds = 1000;
    public const int MaxSourceIdLength = 256;
    public const long MaxChunkBytes = 64L * 1024 * 1024;
    public const long MinFreeBytes = 1024L * 1024 * 1024;
    public const int MaxOutboxWaitSeconds = 25;
    public const int MaxOutboxItemsPerReply = 100;
    /// <summary>Text and links sent inline in one outbox reply; a reply holds at least one item whatever its size.</summary>
    public const int MaxOutboxInlineBytes = 4 * 1024 * 1024;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>A phone's, desktop's or item's id: 8 to 64 letters, digits, '-' and '_', so it is safe as a file name.</summary>
    public static bool IsValidId(string? id)
    {
        if (id is null || id.Length < 8 || id.Length > 64) return false;
        foreach (char c in id)
        {
            if (!(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_')) return false;
        }
        return true;
    }

    public static string NewId() => Guid.NewGuid().ToString("N");

    public static string EncodeBase64Url(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>The bytes of base64url text without padding; null for anything else, stray bits included.</summary>
    public static byte[]? DecodeBase64Url(string? text)
    {
        if (text is null || text.Length % 4 == 1) return null;
        foreach (char c in text)
        {
            if (!(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_')) return null;
        }
        string padded = text.Replace('-', '+').Replace('_', '/').PadRight((text.Length + 3) / 4 * 4, '=');
        try
        {
            byte[] bytes = Convert.FromBase64String(padded);
            return EncodeBase64Url(bytes) == text ? bytes : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static string ToJson<T>(T value) => JsonSerializer.Serialize(value, Json);

    /// <summary>The body read as <typeparamref name="T"/>; null when it is not that JSON.</summary>
    public static T? FromJson<T>(ReadOnlySpan<byte> json) where T : class
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, Json);
        }
        catch (Exception e) when (e is JsonException or DecoderFallbackException or NotSupportedException)
        {
            return null;
        }
    }
}

public static class ErrorCode
{
    public const string Unauthorized = "unauthorized";
    public const string PairingClosed = "pairingClosed";
    public const string TokenInvalid = "tokenInvalid";
    public const string TokenExpired = "tokenExpired";
    public const string TokenUsed = "tokenUsed";
    public const string Declined = "declined";
    public const string TooManyDevices = "tooManyDevices";
    public const string TooLarge = "tooLarge";
    public const string RateLimited = "rateLimited";
    public const string NotFound = "notFound";
    public const string MethodNotAllowed = "methodNotAllowed";
    public const string BadRequest = "badRequest";
    public const string LengthRequired = "lengthRequired";
    public const string Busy = "busy";
    public const string OffsetMismatch = "offsetMismatch";
    public const string HashMismatch = "hashMismatch";
    public const string DiskFull = "diskFull";
    public const string RangeNotSatisfiable = "rangeNotSatisfiable";
    public const string Changed = "changed";
    public const string ServerError = "serverError";
}

/// <summary>What went wrong, for the phone: a stable code and a sentence to show. An offset mismatch also carries the offset to resume from.</summary>
public sealed record LinkError(string Error, string Message, long? Offset = null)
{
    public string ToJson() => Protocol.ToJson(this);

    public static LinkError Unauthorized { get; } =
        new(ErrorCode.Unauthorized, "This computer no longer recognizes this phone. Pair it again.");
    public static LinkError PairingClosed { get; } =
        new(ErrorCode.PairingClosed, "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.");
    public static LinkError TokenInvalid { get; } =
        new(ErrorCode.TokenInvalid, "This pairing code is not valid. Scan the code shown on the computer again.");
    public static LinkError TokenExpired { get; } =
        new(ErrorCode.TokenExpired, "This pairing code has expired. Show a new code on the computer.");
    public static LinkError TokenUsed { get; } =
        new(ErrorCode.TokenUsed, "This pairing code was already used. Show a new code on the computer.");
    public static LinkError Declined { get; } = new(ErrorCode.Declined, "Pairing was declined on the computer.");
    public static LinkError TooManyDevices { get; } =
        new(ErrorCode.TooManyDevices, $"This computer is paired with {PairedDeviceStore.MaxDevices} phones already. Remove one there first.");
    public static LinkError TooLarge { get; } = new(ErrorCode.TooLarge, "The request is larger than this computer takes.");
    public static LinkError RateLimited { get; } = new(ErrorCode.RateLimited, "Too many attempts. Wait a minute, then try again.");
    public static LinkError NotFound { get; } = new(ErrorCode.NotFound, "Not found.");
    public static LinkError MethodNotAllowed { get; } = new(ErrorCode.MethodNotAllowed, "This address does not take that request.");
    public static LinkError BadRequest { get; } = new(ErrorCode.BadRequest, "The request was not understood.");
    public static LinkError LengthRequired { get; } = new(ErrorCode.LengthRequired, "The request must say how long it is (Content-Length).");
    public static LinkError Busy { get; } = new(ErrorCode.Busy, "This file is still being received. Try again in a moment.");
    public static LinkError HashMismatch { get; } =
        new(ErrorCode.HashMismatch, "The file arrived damaged. Send it again from the start.");
    public static LinkError DiskFull { get; } = new(ErrorCode.DiskFull, "This computer is almost out of disk space.");
    public static LinkError RangeNotSatisfiable { get; } =
        new(ErrorCode.RangeNotSatisfiable, "That part of the file is not available.");
    public static LinkError Changed { get; } = new(ErrorCode.Changed, "The file changed on the computer after it was queued.");
    public static LinkError ServerError { get; } = new(ErrorCode.ServerError, "The computer could not store this.");

    public static LinkError OffsetMismatch(long offset) =>
        new(ErrorCode.OffsetMismatch, "The file is not at that offset here. Continue from the offset given.", offset);
}

/// <summary>The body of <c>POST /v1/pair</c>.</summary>
public sealed record PairRequest(string Token = "", string PhoneId = "", string PhoneName = "", string Platform = "", string AppVersion = "")
{
    public const int MaxNameBytes = 128;
}

public sealed record PairResponse(int ProtocolVersion, string DesktopId, string DesktopName, string DeviceSecret);

public sealed record HealthResponse(string Service, int ProtocolVersion, bool Paired);

public sealed record HelloResponse(int ProtocolVersion, string DesktopId, string DesktopName, long MaxChunkBytes);

public static class ItemKind
{
    public const string Text = "text";
    public const string Link = "link";
    public const string File = "file";
}

/// <summary>The body of <c>POST /v1/items</c>.</summary>
public sealed record ItemRequest(string Kind = "", string? Text = null, string? Url = null, string? Name = null, long? Size = null,
                                 string? Mime = null, DateTimeOffset? Modified = null, string? SourceId = null, string? Sha256 = null);

/// <summary>The answer to a file's <c>POST /v1/items</c> and to <c>GET /v1/items/{id}</c>.</summary>
public sealed record ItemState(string Id, long Offset, bool Done, bool? Duplicate = null);

public sealed record GalleryCheckRequest(List<string>? Ids = null);

public sealed record GalleryCheckResponse(List<string> Missing);

/// <summary>An entry of <c>GET /v1/outbox</c>.</summary>
public sealed record OutboxEntry(string Id, string Kind, string? Text = null, string? Url = null, string? Name = null,
                                 long? Size = null, string? Mime = null);

/// <param name="More">True when more is pending than this answer holds; the phone acknowledges these and asks again.</param>
public sealed record OutboxResponse(List<OutboxEntry> Items, bool? More = null);
