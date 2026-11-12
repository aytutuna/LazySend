using System.IO;

namespace LazySend.App.Services;

/// <summary>The lazysend: address other apps use to hand files over: <c>lazysend:open?file=&lt;path&gt;</c>, the file parameter repeated for each file.</summary>
internal static class LazySendUrl
{
    public const string Scheme = "lazysend";

    public static bool IsAddress(string arg) => arg.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);

    /// <summary>The full paths of an open address; empty for any other form (pairing addresses are for phones) and for paths that are not absolute.</summary>
    public static IReadOnlyList<string> Files(string address)
    {
        if (!IsAddress(address)) return [];
        string rest = address[(Scheme.Length + 1)..].TrimStart('/');
        int query = rest.IndexOf('?');
        if (query < 0 || !rest[..query].Equals("open", StringComparison.OrdinalIgnoreCase)) return [];
        var files = new List<string>();
        foreach (string pair in rest[(query + 1)..].Split('&'))
        {
            int equals = pair.IndexOf('=');
            if (equals < 0 || pair[..equals] != "file") continue;
            string path = Uri.UnescapeDataString(pair[(equals + 1)..].Replace('+', ' '));
            if (Path.IsPathFullyQualified(path)) files.Add(path);
        }
        return files;
    }
}
