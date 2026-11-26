using System.Text;
using System.Text.Json;

namespace LazySend.Core.Tests;

public class HarmfulNamesTests
{
    private static readonly string[] DeviceNames =
        ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", .. Enumerable.Range(0, 10).Select(i => $"COM{i}"), .. Enumerable.Range(0, 10).Select(i => $"LPT{i}"),
         "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"];

    private static JsonElement Load()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "testdata", "harmful-names.json"))) dir = Path.GetDirectoryName(dir);
        return JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dir ?? throw new FileNotFoundException("harmful-names.json"), "testdata", "harmful-names.json"))).RootElement;
    }

    private static bool IsWellFormed(string text)
    {
        try
        {
            new UTF8Encoding(false, true).GetBytes(text);
            return true;
        }
        catch (EncoderFallbackException)
        {
            return false;
        }
    }

    [Fact]
    public void EveryHarmfulNameComesOutSafe()
    {
        var data = Load();
        int maxBytes = data.GetProperty("maxFileNameBytes").GetInt32();
        var failures = new List<string>();
        foreach (var c in data.GetProperty("names").EnumerateArray())
        {
            string name = c.GetProperty("name").GetString()!;
            string clean = FileNames.Clean(name);
            string label = $"\"{name}\" became \"{clean}\"";
            if (clean.Length == 0 || Encoding.UTF8.GetByteCount(clean) > maxBytes) failures.Add($"{label}: empty or too long");
            if (clean.Trim('.').Length == 0) failures.Add($"{label}: only dots");
            if (clean.Any(ch => ch is '/' or '\\' or ':' || ch < 0x20 || ch is >= (char)0x7F and <= (char)0x9F)) failures.Add($"{label}: a separator or control character is left");
            if (clean.Any(ch => ch is '؜' or '‎' or '‏' || ch is >= '‪' and <= '‮' || ch is >= '⁦' and <= '⁩')) failures.Add($"{label}: a direction control is left");
            if (clean.EndsWith('.') || clean.EndsWith(' ')) failures.Add($"{label}: ends with a dot or space");
            if (!IsWellFormed(clean)) failures.Add($"{label}: not well-formed");
            if (c.TryGetProperty("keep", out var keep) && !clean.EndsWith(keep.GetString()!)) failures.Add($"{label}: lost the extension");
            if (c.TryGetProperty("exact", out var exact) && clean != exact.GetString()) failures.Add($"{label}: expected {exact}");
            if (c.TryGetProperty("device", out var device) && device.GetBoolean() && DeviceNames.Contains(clean.Split('.')[0].TrimEnd(' '), StringComparer.OrdinalIgnoreCase)) failures.Add($"{label}: still a device name");
        }
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    [Fact]
    public void AHugeNameIsCutInOnePass()
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        string clean = FileNames.Clean(new string('a', 5_000_000) + ".txt");
        Assert.True(clean.EndsWith(".txt") && Encoding.UTF8.GetByteCount(clean) <= FileNames.MaxBytes);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
    }
}
