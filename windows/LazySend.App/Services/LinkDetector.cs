using LazySend.Core;

namespace LazySend.App.Services;

public static class LinkDetector
{
    /// <summary>Whether <paramref name="text"/> is nothing but one http or https address, which is sent as a link.</summary>
    public static bool IsLink(string text)
    {
        string trimmed = text.Trim();
        return trimmed.Length > 0 && !trimmed.Any(char.IsWhiteSpace) && ReceivedLinks.IsAcceptable(trimmed);
    }

    public static string FormatSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double size = bytes;
        int unit = 0;
        while (size >= 1024 && unit < units.Length - 1)
        {
            size /= 1024;
            unit++;
        }
        return unit == 0 ? $"{bytes} B" : $"{size:0.#} {units[unit]}";
    }
}
