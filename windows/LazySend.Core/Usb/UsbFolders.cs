using System.Security.Cryptography;
using System.Text;

namespace LazySend.Core;

/// <summary>The folder name to import into, or the paired phones to ask about when there is more than one candidate.</summary>
public sealed record UsbFolder(string? Name, IReadOnlyList<PairedDevice> Choose);

public sealed class UsbFoldersFile
{
    /// <summary>
    /// Per USB device key: a paired phone's id, "=folder" for a name taken from the USB device (looked at again
    /// when a phone of its kind is paired later) or "!folder" for a name the user chose over every paired phone.
    /// </summary>
    public Dictionary<string, string> Map { get; set; } = [];
}

/// <summary>
/// Decides which folder under the receive folder a phone on USB imports into. An iPhone is listed by Windows as
/// "Apple iPhone" whoever owns it, so a paired phone of the same kind gives the name instead and Wi-Fi and USB
/// photos end up together. Safe to use from any thread.
/// </summary>
public sealed class UsbFolders(string file, Func<IReadOnlyList<PairedDevice>> paired)
{
    private readonly object _gate = new();
    private readonly UsbFoldersFile _file = JsonFile.Load<UsbFoldersFile>(file);

    public static string Key(string deviceId) =>
        "usb-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(deviceId)))[..32];

    public UsbFolder Resolve(string deviceId, string friendlyName, bool apple)
    {
        string key = Key(deviceId);
        lock (_gate)
        {
            var phones = paired();
            if (_file.Map.TryGetValue(key, out string? saved))
            {
                if (saved.StartsWith('!')) return new UsbFolder(saved[1..], []);
                if (!saved.StartsWith('=') && phones.FirstOrDefault(p => p.Id == saved) is { } remembered) return new UsbFolder(remembered.Name, []);
            }
            var candidates = phones.Where(p => IsApple(p.Platform) == apple && (apple || p.Platform.Contains("android", StringComparison.OrdinalIgnoreCase))).ToList();
            if (candidates.Count == 1)
            {
                Save(key, candidates[0].Id);
                return new UsbFolder(candidates[0].Name, []);
            }
            if (candidates.Count > 1) return new UsbFolder(null, candidates);
            if (saved is { } && saved.StartsWith('=')) return new UsbFolder(saved[1..], []);
            string folder = Unused(key, friendlyName);
            Save(key, "=" + folder);
            return new UsbFolder(folder, []);
        }
    }

    /// <summary>Remembers the answer to a question: a paired phone, or null for a folder of its own named after the USB device.</summary>
    public string Choose(string deviceId, string friendlyName, PairedDevice? phone)
    {
        string key = Key(deviceId);
        lock (_gate)
        {
            if (phone is not null)
            {
                Save(key, phone.Id);
                return phone.Name;
            }
            string folder = Unused(key, friendlyName);
            Save(key, "!" + folder);
            return folder;
        }
    }

    private static bool IsApple(string platform) =>
        platform.StartsWith("ios", StringComparison.OrdinalIgnoreCase) || platform.StartsWith("ipad", StringComparison.OrdinalIgnoreCase);

    // The first device to use a name keeps it; another one with the same name gets a short id after it.
    private string Unused(string key, string friendlyName)
    {
        string name = FileNames.Clean(friendlyName, "Phone");
        bool taken = _file.Map.Any(e => e.Key != key && e.Value.Length > 1 && e.Value[0] is '=' or '!'
                                        && string.Equals(e.Value[1..], name, StringComparison.OrdinalIgnoreCase));
        return taken ? $"{name} ({key[4..8]})" : name;
    }

    private void Save(string key, string value)
    {
        if (_file.Map.TryGetValue(key, out string? old) && old == value) return;
        _file.Map[key] = value;
        JsonFile.Save(file, _file);
    }
}
