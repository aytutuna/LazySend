using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media.Imaging;

namespace LazySend.App.Services;

/// <summary>Pictures pasted into the app are saved as PNG files, which stay until nothing waiting refers to them.</summary>
public static class ClipboardFiles
{
    /// <summary>A name no other pasted picture has: the time to the second and a short random suffix.</summary>
    public static string NewImagePath(string folder, DateTime now) =>
        Path.Combine(folder, $"Clipboard {now:yyyy-MM-dd HH-mm-ss} {Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(2))}.png");

    private static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".heic", ".webp"];

    /// <summary>
    /// Puts text, or a file, on the clipboard; a picture goes as the bitmap and the file both, so Paint and Explorer each get what they ask for.
    /// False when another program holds the clipboard. Call it on the UI thread.
    /// </summary>
    public static bool Put(string? text, string? path)
    {
        try
        {
            if (path is null)
            {
                if (string.IsNullOrEmpty(text)) return false;
                Clipboard.SetText(text);
                return true;
            }
            var data = new DataObject();
            if (ImageExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase) && Decode(path) is { } image) data.SetImage(image);
            data.SetFileDropList(new StringCollection { path });
            Clipboard.SetDataObject(data, true);
            return true;
        }
        catch (COMException)
        {
            return false;
        }
    }

    // A format Windows has no codec for (HEIC without the extension, WebP) leaves the file alone on the clipboard.
    private static BitmapSource? Decode(string path)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(path);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or IOException or COMException or UnauthorizedAccessException)
        {
            return null;
        }
    }

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
