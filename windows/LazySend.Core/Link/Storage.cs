using System.Text;
using System.Text.Json;

namespace LazySend.Core;

/// <summary>Where Lazy Send keeps its files: settings under %APPDATA%, state under %LOCALAPPDATA%, received files in Downloads.</summary>
public sealed record SendPaths(string Settings, string State, string DefaultReceiveRoot)
{
    public static SendPaths Default => new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lazy Send"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lazy Send"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Lazy Send"));

    public string DevicesFile => Path.Combine(Settings, "devices.json");
    public string SettingsFile => Path.Combine(Settings, "settings.json");
    public string HistoryFile => Path.Combine(State, "history.json");
    public string IncomingDirectory => Path.Combine(State, "incoming");
    public string IndexDirectory => Path.Combine(State, "index");
    public string OutboxFile => Path.Combine(State, "outbox.json");
}

public sealed class SendSettingsFile
{
    /// <summary>The folder received files go under; "" for the default in Downloads.</summary>
    public string ReceiveFolder { get; set; } = "";
}

/// <summary>The user's choices. Changes are written at once.</summary>
public sealed class SendSettings(SendPaths paths)
{
    private readonly object _gate = new();
    private SendSettingsFile _file = JsonFile.Load<SendSettingsFile>(paths.SettingsFile);

    /// <summary>The folder received files go under, one folder per phone inside it.</summary>
    public string ReceiveRoot
    {
        get
        {
            lock (_gate) return _file.ReceiveFolder.Length > 0 ? _file.ReceiveFolder : paths.DefaultReceiveRoot;
        }
        set
        {
            lock (_gate)
            {
                _file.ReceiveFolder = value == paths.DefaultReceiveRoot ? "" : value;
                JsonFile.Save(paths.SettingsFile, _file);
            }
        }
    }
}

/// <summary>JSON files written whole through a temporary file, so a crash leaves the old one or the new one.</summary>
internal static class JsonFile
{
    private static readonly JsonSerializerOptions Options = new(Protocol.Json) { WriteIndented = true };

    /// <summary>The file's value; a new one when there is no file, and a file that does not read is kept as .bad.</summary>
    public static T Load<T>(string path) where T : class, new()
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return new T();
        }
        try
        {
            return JsonSerializer.Deserialize<T>(data, Options) ?? new T();
        }
        catch (Exception e) when (e is JsonException or DecoderFallbackException)
        {
            File.Move(path, path + ".bad", overwrite: true);
            return new T();
        }
    }

    public static void Save<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".tmp";
        File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(value, Options));
        File.Move(temp, path, overwrite: true);
    }
}

/// <summary>Names from phones made safe as Windows file and folder names.</summary>
public static class FileNames
{
    public const int MaxBytes = 240;

    private static readonly string[] ReservedDeviceNames =
        ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", .. Enumerable.Range(0, 10).Select(i => $"COM{i}"), .. Enumerable.Range(0, 10).Select(i => $"LPT{i}")];

    /// <summary>
    /// A name that can be created: path separators and characters Windows refuses become '_', trailing
    /// dots and spaces go, a device name such as NUL gets '_' in front, and the stem is cut so the whole
    /// is at most <see cref="MaxBytes"/> UTF-8 bytes (room for " (2)"). Empty names become <paramref name="fallback"/>.
    /// </summary>
    public static string Clean(string? name, string fallback = "file")
    {
        var text = new StringBuilder();
        foreach (var rune in (name ?? "").EnumerateRunes())
        {
            bool bad = rune.Value < 0x20 || rune.Value is >= 0x7F and <= 0x9F || (rune.Value < 0x80 && "<>:\"/\\|?*".Contains((char)rune.Value));
            text.Append(bad ? "_" : rune.ToString());
        }
        string cleaned = text.ToString().Trim().TrimEnd('.', ' ');
        if (cleaned.Length == 0) cleaned = fallback;
        string extension = Path.GetExtension(cleaned);
        string stem = cleaned[..^extension.Length];
        if (stem.Length == 0) (stem, extension) = (cleaned, "");
        if (ReservedDeviceNames.Contains(stem, StringComparer.OrdinalIgnoreCase)) stem = "_" + stem;
        if (Encoding.UTF8.GetByteCount(extension) > 32) extension = "";
        while (Encoding.UTF8.GetByteCount(stem) + Encoding.UTF8.GetByteCount(extension) > MaxBytes) stem = stem[..^1];
        // A cut can leave half a surrogate pair.
        if (stem.Length > 0 && char.IsHighSurrogate(stem[^1])) stem = stem[..^1];
        stem = stem.TrimEnd('.', ' ');
        return (stem.Length == 0 ? fallback : stem) + extension;
    }

    /// <summary>The first of <c>name</c>, <c>name (2)</c>, <c>name (3)</c>… that does not exist in <paramref name="directory"/>.</summary>
    public static string Unique(string directory, string name)
    {
        string extension = Path.GetExtension(name);
        string stem = name[..^extension.Length];
        string candidate = name;
        for (int n = 2; File.Exists(Path.Combine(directory, candidate)) || Directory.Exists(Path.Combine(directory, candidate)); n++)
        {
            candidate = $"{stem} ({n}){extension}";
        }
        return candidate;
    }
}
