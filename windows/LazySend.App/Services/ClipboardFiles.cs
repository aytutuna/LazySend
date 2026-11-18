using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LazySend.App.Services;

/// <summary>Pictures pasted into the app are saved as PNG files, which stay until nothing waiting refers to them.</summary>
public static class ClipboardFiles
{
    /// <summary>A name no other pasted picture has: the time to the second and a short random suffix.</summary>
    public static string NewImagePath(string folder, DateTime now) =>
        Path.Combine(folder, $"Clipboard {now:yyyy-MM-dd HH-mm-ss} {Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(2))}.png");

    /// <summary>Extensions of what is shown as a picture and put on the clipboard as one.</summary>
    public static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic"];

    /// <summary>Pictures over this many pixels, or files over <see cref="MaxImageBytes"/>, are not decoded.</summary>
    public const long MaxPixels = 50_000_000;
    public const long MaxImageBytes = 64L * 1024 * 1024;

    public static bool IsImage(string path) => ImageExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Puts text, or files, on the clipboard; a single picture goes as the bitmap (upright, and as PNG data for a PNG) and the file
    /// both, so Paint, Office and Explorer each get what they ask for. False when another program holds the clipboard.
    /// Call it on the UI thread.
    /// </summary>
    public static bool Put(string? text, IReadOnlyList<string>? paths)
    {
        try
        {
            if (paths is not { Count: > 0 })
            {
                if (string.IsNullOrEmpty(text)) return false;
                Clipboard.SetText(text);
                return true;
            }
            var data = new DataObject();
            if (paths.Count == 1 && IsImage(paths[0])) AddImage(data, paths[0]);
            var list = new StringCollection();
            list.AddRange([.. paths]);
            data.SetFileDropList(list);
            Clipboard.SetDataObject(data, true);
            return true;
        }
        catch (COMException)
        {
            return false;
        }
    }

    // A format Windows has no codec for (HEIC without the extension, WebP) or a huge picture leaves the file alone on the clipboard.
    private static void AddImage(DataObject data, string path)
    {
        try
        {
            if (new FileInfo(path).Length > MaxImageBytes) return;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var probe = BitmapDecoder.Create(stream, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None).Frames[0];
            if ((long)probe.PixelWidth * probe.PixelHeight > MaxPixels) return;
            stream.Position = 0;
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            BitmapSource image = Upright(frame);
            image.Freeze();
            data.SetImage(image);
            if (Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase))
            {
                // The bitmap format has no transparency; Office and browsers ask for PNG data first.
                stream.Position = 0;
                var png = new MemoryStream();
                stream.CopyTo(png);
                data.SetData("PNG", png);
            }
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or IOException or COMException or UnauthorizedAccessException
                                      or InvalidOperationException)
        {
            // The file drop list is still put.
        }
    }

    /// <summary>The picture turned the way its EXIF orientation says, as a phone's camera writes it.</summary>
    internal static BitmapSource Upright(BitmapFrame frame)
    {
        int orientation = 1;
        try
        {
            if (frame.Metadata is BitmapMetadata metadata && metadata.GetQuery("/app1/ifd/{ushort=274}") is ushort value) orientation = value;
        }
        catch (Exception e) when (e is NotSupportedException or ArgumentException or InvalidOperationException or COMException)
        {
            // No metadata of that kind: the picture is as stored.
        }
        BitmapSource image = frame;
        // Mirrored cases are a turn and then a flip across the vertical axis.
        int turn = orientation switch { 3 => 180, 6 or 5 => 90, 8 or 7 => 270, _ => 0 };
        if (turn != 0) image = new TransformedBitmap(image, new RotateTransform(turn));
        if (orientation is 2 or 4 or 5 or 7) image = new TransformedBitmap(image, new ScaleTransform(orientation == 4 ? 1 : -1, orientation == 4 ? -1 : 1));
        return image;
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
