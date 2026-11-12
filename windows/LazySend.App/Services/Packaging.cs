using System.Runtime.InteropServices;
using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;

namespace LazySend.App.Services;

/// <summary>
/// Whether the app runs from an MSIX package (the Store build). Windows then keeps the app's registry and
/// AppData writes in the package's own store, so the Run key is no use for starting with Windows and the exe
/// path inside WindowsApps is not one a shortcut can launch.
/// </summary>
internal static class Packaging
{
    private const int ErrorInsufficientBuffer = 122;

    /// <summary>Settable so a test can stand in for the packaged app; nothing else changes it.</summary>
    internal static bool IsPackaged { get; set; } = Query();

    /// <summary>
    /// GetCurrentPackageFullName with no buffer: a packaged process answers that the buffer is too small, an
    /// unpackaged one that it has no package (APPMODEL_ERROR_NO_PACKAGE).
    /// </summary>
    internal static bool IsPackageResult(int result) => result == ErrorInsufficientBuffer;

    /// <summary>A startup task cannot pass --minimized, so the activation says whether Windows started the app at sign-in.</summary>
    internal static bool StartedAtSignIn()
    {
        if (!IsPackaged) return false;
        try
        {
            return AppInstance.GetActivatedEventArgs()?.Kind == ActivationKind.StartupTask;
        }
        catch (COMException)
        {
            return false;
        }
    }

    private static bool Query()
    {
        int length = 0;
        return IsPackageResult(GetCurrentPackageFullName(ref length, null));
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref int length, char[]? name);
}
