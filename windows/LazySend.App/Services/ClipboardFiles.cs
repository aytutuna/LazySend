using System.IO;
using System.Security.Cryptography;

namespace LazySend.App.Services;

/// <summary>Pictures pasted into the app are saved as PNG files, which stay until nothing waiting refers to them.</summary>
public static class ClipboardFiles
{
    /// <summary>A name no other pasted picture has: the time to the second and a short random suffix.</summary>
    public static string NewImagePath(string folder, DateTime now) =>
        Path.Combine(folder, $"Clipboard {now:yyyy-MM-dd HH-mm-ss} {Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(2))}.png");

    public static void Cleanup(string folder, IEnumerable<string> referenced)
    {
        if (!Directory.Exists(folder)) return;
        var keep = new HashSet<string>(referenced.Select(Path.GetFullPath), StringComparer.OrdinalIgnoreCase);
        foreach (string file in Directory.EnumerateFiles(folder))
        {
            if (keep.Contains(Path.GetFullPath(file))) continue;
            try
            {
                File.Delete(file);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Tried again at the next start.
            }
        }
    }
}
