namespace LazySend.App.Services;

/// <summary>The lazysend: address, used for pairing links only. It never names a file to send.</summary>
internal static class LazySendUrl
{
    public const string Scheme = "lazysend";

    public static bool IsAddress(string arg) => arg.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);
}
