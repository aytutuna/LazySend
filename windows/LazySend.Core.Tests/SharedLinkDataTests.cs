using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LazySend.Core;

namespace LazySend.Core.Tests;

/// <summary>Reads testdata/link, the phone link's shared test data, and checks this code base against every case in it.</summary>
public class SharedLinkDataTests
{
    private static JsonElement Load(string file)
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "testdata", "link", file))) dir = Path.GetDirectoryName(dir);
        if (dir is null) throw new FileNotFoundException(file);
        return JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dir, "testdata", "link", file))).RootElement;
    }

    private static void NoFailures(List<string> failures) => Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));

    private static byte[] Pattern(long from, long to)
    {
        var data = new byte[to - from];
        for (long i = from; i < to; i++) data[i - from] = (byte)(i % 251);
        return data;
    }

    private static string Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private static string? Str(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v.GetString() : null;

    [Fact]
    public void PairingCodesAreReadAsTheDataSays()
    {
        var failures = new List<string>();
        foreach (var c in Load("pairing-uris.json").GetProperty("cases").EnumerateArray())
        {
            string name = c.GetProperty("name").GetString()!;
            string result = c.GetProperty("result").GetString()!;
            var uri = PairingUri.TryParse(c.GetProperty("uri").GetString()!, out var error);
            if (result != "ok")
            {
                if (uri is not null || !string.Equals(error!.Kind.ToString(), result, StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add($"{name}: expected {result}, got {(uri is null ? error!.Kind.ToString() : "a code")}");
                }
                continue;
            }
            if (uri is null)
            {
                failures.Add($"{name}: refused with {error!.Kind}");
                continue;
            }
            var p = c.GetProperty("pairing");
            bool same = uri.DesktopId == p.GetProperty("desktopId").GetString() && uri.Name == p.GetProperty("name").GetString()
                        && uri.Fingerprint == p.GetProperty("fingerprint").GetString() && uri.Port == p.GetProperty("port").GetInt32()
                        && uri.Token == p.GetProperty("token").GetString()
                        && uri.Addresses.SequenceEqual(p.GetProperty("addresses").EnumerateArray().Select(a => a.GetString()!))
                        && SpkiFingerprint.Spaced(SpkiFingerprint.CheckCode(uri.FingerprintBytes!)) == p.GetProperty("checkCode").GetString();
            if (!same) failures.Add($"{name}: the parts differ");
            if (PairingUri.Parse(uri.Format()) != uri) failures.Add($"{name}: formatting and reading again gives another code");
        }
        NoFailures(failures);
    }

    [Fact]
    public void CheckCodesMatch()
    {
        foreach (var c in Load("check-codes.json").GetProperty("cases").EnumerateArray())
        {
            byte[] fingerprint = c.GetProperty("fingerprint").EnumerateArray().Select(b => (byte)b.GetInt32()).ToArray();
            Assert.Equal(c.GetProperty("checkCode").GetString(), SpkiFingerprint.Spaced(SpkiFingerprint.CheckCode(fingerprint)));
            Assert.Equal(c.GetProperty("matchCode").GetString(),
                         SpkiFingerprint.Spaced(SpkiFingerprint.MatchCode(fingerprint, c.GetProperty("shortCode").GetString()!)));
        }
    }

    [Fact]
    public void ShortCodesAreReadAndRedeemedAsTheDataSays()
    {
        var data = Load("short-codes.json");
        Assert.Equal("0123456789ABCDEFGHJKMNPQRSTVWXYZ", data.GetProperty("alphabet").GetString());
        var failures = new List<string>();
        foreach (var n in data.GetProperty("normalize").EnumerateArray())
        {
            string? typed = Str(n, "typed");
            string? expected = Str(n, "canonical");
            if (PairingSession.NormalizeShortCode(typed) != expected) failures.Add($"normalize \"{typed}\": expected {expected ?? "nothing"}");
        }
        byte[] token = data.GetProperty("tokenBytes").EnumerateArray().Select(b => (byte)b.GetInt32()).ToArray();
        var opened = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        foreach (var r in data.GetProperty("redeem").EnumerateArray())
        {
            var session = new PairingSession(opened, token);
            string typed = session.ShortCode[..4].ToLowerInvariant() + "-" + session.ShortCode[4..].ToLowerInvariant();
            int step = 0;
            foreach (var a in r.GetProperty("attempts").EnumerateArray())
            {
                step++;
                string? presented = Str(a, "token") switch
                {
                    "$token" => session.Token,
                    "$shortCode" => session.ShortCode,
                    "$shortCodeTyped" => typed,
                    var other => other,
                };
                var got = session.Redeem(presented, opened.AddSeconds(a.GetProperty("at").GetInt32()), IPAddress.Parse(a.GetProperty("peer").GetString()!));
                if (!string.Equals(got.ToString(), a.GetProperty("expect").GetString(), StringComparison.OrdinalIgnoreCase))
                {
                    failures.Add($"{r.GetProperty("name").GetString()}, attempt {step}: expected {a.GetProperty("expect").GetString()}, got {got}");
                }
            }
        }
        NoFailures(failures);
    }

    private static Dictionary<string, object?> Fields(string type, byte[] body) => type switch
    {
        "PairRequest" => Protocol.FromJson<PairRequest>(body) is { } v
            ? new() { ["token"] = v.Token, ["phoneId"] = v.PhoneId, ["phoneName"] = v.PhoneName, ["platform"] = v.Platform, ["appVersion"] = v.AppVersion }
            : throw new JsonException(),
        "PairResponse" => Protocol.FromJson<PairResponse>(body) is { } v
            ? new() { ["protocolVersion"] = v.ProtocolVersion, ["desktopId"] = v.DesktopId, ["desktopName"] = v.DesktopName, ["deviceSecret"] = v.DeviceSecret }
            : throw new JsonException(),
        "Hello" => Protocol.FromJson<HelloResponse>(body) is { } v
            ? new() { ["protocolVersion"] = v.ProtocolVersion, ["desktopId"] = v.DesktopId, ["desktopName"] = v.DesktopName, ["maxChunkBytes"] = v.MaxChunkBytes, ["addresses"] = v.Addresses }
            : throw new JsonException(),
        "ItemRequest" => Protocol.FromJson<ItemRequest>(body) is { } v
            ? new()
            {
                ["kind"] = v.Kind, ["text"] = v.Text, ["url"] = v.Url, ["name"] = v.Name, ["size"] = v.Size, ["mime"] = v.Mime,
                ["sourceId"] = v.SourceId, ["sha256"] = v.Sha256, ["sendId"] = v.SendId, ["clip"] = v.Clip,
            }
            : throw new JsonException(),
        "ItemState" => Protocol.FromJson<ItemState>(body) is { } v
            ? new() { ["id"] = v.Id, ["offset"] = v.Offset, ["done"] = v.Done, ["duplicate"] = v.Duplicate }
            : throw new JsonException(),
        "OutboxReply" => Protocol.FromJson<OutboxResponse>(body) is { } v
            ? new()
            {
                ["ids"] = v.Items.Select(i => i.Id).ToList(), ["kinds"] = v.Items.Select(i => i.Kind).ToList(), ["more"] = v.More ?? false,
                ["firstText"] = v.Items.ElementAtOrDefault(0)?.Text, ["firstClip"] = v.Items.ElementAtOrDefault(0)?.Clip,
                ["secondUrl"] = v.Items.ElementAtOrDefault(1)?.Url, ["thirdName"] = v.Items.ElementAtOrDefault(2)?.Name, ["thirdSize"] = v.Items.ElementAtOrDefault(2)?.Size,
            }
            : throw new JsonException(),
        "ApiError" => Protocol.FromJson<LinkError>(body) is { } v
            ? new() { ["error"] = v.Error, ["message"] = v.Message, ["offset"] = v.Offset }
            : throw new JsonException(),
        _ => throw new ArgumentException(type),
    };

    private static bool Matches(JsonElement expected, object? actual) => expected.ValueKind switch
    {
        JsonValueKind.Null => actual is null,
        JsonValueKind.String => actual as string == expected.GetString(),
        JsonValueKind.True => actual is true,
        JsonValueKind.False => actual is false,
        JsonValueKind.Number => actual is not null and not string && Convert.ToInt64(actual) == expected.GetInt64(),
        JsonValueKind.Array => actual is IEnumerable<string> list && list.SequenceEqual(expected.EnumerateArray().Select(e => e.GetString()!)),
        _ => false,
    };

    [Fact]
    public void MessagesAreReadAsTheDataSays()
    {
        var data = Load("messages.json");
        var failures = new List<string>();
        foreach (var c in data.GetProperty("cases").EnumerateArray())
        {
            string name = c.GetProperty("name").GetString()!;
            try
            {
                var fields = Fields(c.GetProperty("type").GetString()!, Encoding.UTF8.GetBytes(c.GetProperty("json").GetRawText()));
                foreach (var e in c.GetProperty("expect").EnumerateObject())
                {
                    if (!fields.TryGetValue(e.Name, out var actual) || !Matches(e.Value, actual)) failures.Add($"{name}: {e.Name} is {actual ?? "absent"}, expected {e.Value}");
                }
            }
            catch (JsonException)
            {
                failures.Add($"{name}: not read");
            }
        }
        foreach (var c in data.GetProperty("invalid").EnumerateArray())
        {
            try
            {
                Fields(c.GetProperty("type").GetString()!, Encoding.UTF8.GetBytes(c.GetProperty("body").GetString()!));
                failures.Add($"{c.GetProperty("name").GetString()}: read although it is not valid");
            }
            catch (JsonException)
            {
            }
        }
        var codes = typeof(ErrorCode).GetFields().Select(f => (string)f.GetRawConstantValue()!).Order().ToList();
        if (!codes.SequenceEqual(data.GetProperty("errorCodes").EnumerateArray().Select(e => e.GetString()!).Order())) failures.Add("the error codes differ");
        NoFailures(failures);
    }

    [Fact]
    public void NamesAndIdsAreMadeSafeAsTheDataSays()
    {
        var data = Load("names.json");
        int maxBytes = data.GetProperty("maxFileNameBytes").GetInt32();
        var failures = new List<string>();
        foreach (var c in data.GetProperty("cleanFileName").EnumerateArray())
        {
            string? name = Str(c, "name");
            string clean = FileNames.Clean(name);
            string label = $"\"{name}\" became \"{clean}\"";
            if (clean.Length == 0 || Encoding.UTF8.GetByteCount(clean) > maxBytes) failures.Add($"{label}: empty or too long");
            if (clean.Any(ch => ch is '/' or '\\' or ':' || ch < 0x20 || ch is >= (char)0x7F and <= (char)0x9F)) failures.Add($"{label}: a separator or control character is left");
            if (clean.EndsWith('.') || clean.EndsWith(' ')) failures.Add($"{label}: ends with a dot or space");
            if (!IsWellFormed(clean)) failures.Add($"{label}: not well-formed text");
            if (Str(c, "keep") is { } keep && !clean.EndsWith(keep)) failures.Add($"{label}: lost {keep}");
            if (Str(c, "exact") is { } exact && clean != exact) failures.Add($"{label}: expected {exact}");
        }
        foreach (var id in data.GetProperty("validIds").EnumerateArray()) if (!Protocol.IsValidId(id.GetString())) failures.Add($"id {id} refused");
        foreach (var id in data.GetProperty("invalidIds").EnumerateArray()) if (Protocol.IsValidId(id.GetString())) failures.Add($"id {id} accepted");
        NoFailures(failures);
    }

    private static bool IsWellFormed(string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) i++;
            else if (char.IsSurrogate(text[i])) return false;
        }
        return true;
    }

    [Fact]
    public void LargeFileIsDescribedByItsSizeAndFingerprint()
    {
        var data = Load("large-file.json");
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long size = data.GetProperty("size").GetInt64();
        for (long at = 0; at < size; at += 1 << 20) sha.AppendData(Pattern(at, Math.Min(size, at + (1 << 20))));
        Assert.Equal(data.GetProperty("sha256").GetString(), Convert.ToHexStringLower(sha.GetHashAndReset()));
    }

    [Fact]
    public async Task SessionsRunAsTheDataSays()
    {
        var data = Load("sessions.json");
        var large = Load("large-file.json");
        foreach (var c in data.GetProperty("cases").EnumerateArray())
        {
            if (c.TryGetProperty("readers", out var readers) && !readers.EnumerateArray().Any(r => r.GetString() == "csharp")) continue;
            await using var h = new Harness();
            using var phone = await h.PairAsync("Test iPhone");
            var run = new Session(h, phone, large);
            int step = 0;
            foreach (var s in c.GetProperty("steps").EnumerateArray())
            {
                step++;
                try
                {
                    await run.StepAsync(s);
                }
                catch (Exception e) when (e is Xunit.Sdk.XunitException)
                {
                    throw new Xunit.Sdk.XunitException($"{c.GetProperty("name").GetString()}, step {step} ({s.GetProperty("op").GetString()}): {e.Message}");
                }
            }
        }
    }

    private sealed class Session(Harness h, Phone phone, JsonElement large)
    {
        private string _id = "";
        private long _size;
        private long _offset;
        private long _settled;
        private List<string> _polled = [];
        private readonly string _folder = Path.Combine(h.ReceivedRoot, "Test iPhone");

        private long SizeOf(JsonElement content) => content.ValueKind == JsonValueKind.String ? large.GetProperty("size").GetInt64() : content.GetProperty("size").GetInt64();

        private static void CheckState(JsonElement expect, ItemState state)
        {
            if (expect.TryGetProperty("offset", out var o)) Assert.Equal(o.GetInt64(), state.Offset);
            if (expect.TryGetProperty("done", out var d)) Assert.Equal(d.GetBoolean(), state.Done);
        }

        public async Task StepAsync(JsonElement s)
        {
            switch (s.GetProperty("op").GetString())
            {
                case "begin":
                {
                    _size = SizeOf(s.GetProperty("content"));
                    string? sha = s.TryGetProperty("hash", out _) ? (s.GetProperty("content").ValueKind == JsonValueKind.String
                        ? large.GetProperty("sha256").GetString() : Hex(Pattern(0, _size)))
                        : s.TryGetProperty("hashOfOther", out _) ? Hex("other"u8.ToArray()) : null;
                    using var response = await phone.PostAsync(Protocol.ItemsPath,
                        new ItemRequest(ItemKind.File, Name: s.GetProperty("name").GetString(), Size: _size, Sha256: sha));
                    response.EnsureSuccessStatusCode();
                    var state = await Harness.ReadAsync<ItemState>(response);
                    _id = state.Id;
                    _offset = state.Offset;
                    CheckState(s.GetProperty("expect"), state);
                    break;
                }
                case "put":
                {
                    long from = s.GetProperty("from").GetInt64(), to = s.GetProperty("to").GetInt64();
                    using var response = await phone.PutChunkAsync(_id, from, Pattern(from, to));
                    response.EnsureSuccessStatusCode();
                    var state = await Harness.ReadAsync<ItemState>(response);
                    _offset = state.Offset;
                    CheckState(s.GetProperty("expect"), state);
                    break;
                }
                case "putAll":
                {
                    long chunk = s.GetProperty("chunk").GetInt64();
                    ItemState? last = null;
                    while (_offset < _size)
                    {
                        using var response = await phone.PutChunkAsync(_id, _offset, Pattern(_offset, Math.Min(_size, _offset + chunk)));
                        response.EnsureSuccessStatusCode();
                        last = await Harness.ReadAsync<ItemState>(response);
                        _offset = last.Offset;
                    }
                    CheckState(s.GetProperty("expect"), last!);
                    break;
                }
                case "putError":
                {
                    long from = s.GetProperty("from").GetInt64(), to = s.GetProperty("to").GetInt64();
                    using var response = await phone.PutChunkAsync(_id, from, Pattern(from, to));
                    await CheckErrorAsync(s, response);
                    break;
                }
                case "drop":
                    await phone.DropMidChunkAsync(_id, s.GetProperty("offset").GetInt64(), s.GetProperty("declared").GetInt64(),
                                                  Pattern(s.GetProperty("offset").GetInt64(), s.GetProperty("offset").GetInt64() + s.GetProperty("sent").GetInt64()));
                    await Task.Delay(300);
                    break;
                case "settle":
                {
                    long last = -1;
                    for (int i = 0; i < 100; i++)
                    {
                        long offset = (await phone.GetStateAsync(_id)).Offset;
                        if (offset == last) break;
                        last = offset;
                        await Task.Delay(150);
                    }
                    var between = s.GetProperty("between");
                    Assert.InRange(last, between[0].GetInt64(), between[1].GetInt64());
                    _settled = last;
                    break;
                }
                case "resume":
                {
                    using var response = await phone.PutChunkAsync(_id, _settled, Pattern(_settled, _size));
                    response.EnsureSuccessStatusCode();
                    CheckState(s.GetProperty("expect"), await Harness.ReadAsync<ItemState>(response));
                    break;
                }
                case "state":
                    CheckState(s.GetProperty("expect"), await phone.GetStateAsync(_id));
                    break;
                case "stateError":
                {
                    using var response = await phone.SendAsync(HttpMethod.Get, Protocol.ItemsPrefix + _id);
                    await CheckErrorAsync(s, response);
                    break;
                }
                case "restart":
                    await h.RestartAsync();
                    break;
                case "expectFile":
                {
                    string path = Path.Combine(_folder, s.GetProperty("name").GetString()!);
                    var content = s.GetProperty("content");
                    if (content.ValueKind == JsonValueKind.String)
                    {
                        using var stream = File.OpenRead(path);
                        Assert.Equal(large.GetProperty("sha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(stream)));
                    }
                    else
                    {
                        Assert.Equal(Pattern(0, content.GetProperty("size").GetInt64()), await File.ReadAllBytesAsync(path));
                    }
                    break;
                }
                case "expectNoFile":
                    Assert.False(File.Exists(Path.Combine(_folder, s.GetProperty("name").GetString()!)));
                    break;
                case "post":
                {
                    string kind = s.GetProperty("kind").GetString()!;
                    using var response = await phone.PostAsync(Protocol.ItemsPath, kind == "text"
                        ? new ItemRequest(ItemKind.Text, Text: s.GetProperty("text").GetString())
                        : new ItemRequest(ItemKind.Link, Url: s.GetProperty("url").GetString()));
                    Assert.Equal(HttpStatusCode.Created, response.StatusCode);
                    h.Now += TimeSpan.FromSeconds(1);
                    break;
                }
                case "expectReceived":
                {
                    var got = h.Service.History.Items.Reverse().Select(i => (i.Kind, i.Kind == ItemKind.Text ? i.Text : i.Url)).ToList();
                    var want = s.GetProperty("items").EnumerateArray().Select(i => (i[0].GetString()!, i[1].GetString())).ToList();
                    Assert.Equal(want, got);
                    break;
                }
                case "queue":
                    if (s.GetProperty("kind").GetString() == "text") h.Service.Outbox.QueueText(phone.Id, s.GetProperty("text").GetString()!);
                    else h.Service.Outbox.QueueLink(phone.Id, s.GetProperty("url").GetString()!);
                    break;
                case "poll":
                {
                    using var response = await phone.SendAsync(HttpMethod.Get, $"{Protocol.OutboxPath}?wait=0");
                    response.EnsureSuccessStatusCode();
                    var items = (await Harness.ReadAsync<OutboxResponse>(response)).Items;
                    _polled = items.Select(i => i.Id).ToList();
                    var want = s.GetProperty("items").EnumerateArray().Select(i => (i[0].GetString()!, i[1].GetString())).ToList();
                    Assert.Equal(want, items.Select(i => (i.Kind, i.Kind == ItemKind.Text ? i.Text : i.Url)).ToList());
                    break;
                }
                case "ack":
                {
                    using var response = await phone.SendAsync(HttpMethod.Delete, Protocol.OutboxPrefix + _polled[s.GetProperty("index").GetInt32()]);
                    response.EnsureSuccessStatusCode();
                    _polled.RemoveAt(s.GetProperty("index").GetInt32());
                    break;
                }
                default:
                    throw new ArgumentException(s.GetProperty("op").GetString());
            }
        }

        private static async Task CheckErrorAsync(JsonElement s, HttpResponseMessage response)
        {
            Assert.Equal(s.GetProperty("status").GetInt32(), (int)response.StatusCode);
            var error = await Harness.ReadAsync<LinkError>(response);
            Assert.Equal(s.GetProperty("code").GetString(), error.Error);
            if (s.TryGetProperty("offset", out var offset)) Assert.Equal(offset.GetInt64(), error.Offset);
        }
    }
}
