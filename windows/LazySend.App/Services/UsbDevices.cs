using System.Runtime.InteropServices;

namespace LazySend.App.Services;

internal static class UsbDevices
{
    private const uint FilterEnumerator = 0x1;
    private const uint FilterPresent = 0x100;
    private const string AppleVendor = "VID_05AC&PID_12";

    /// <summary>Whether an iPhone or iPad is on a USB port, driver or not; Windows lists it as a portable device only with Apple's driver.</summary>
    public static bool AppleMobileDevicePresent()
    {
        const uint flags = FilterEnumerator | FilterPresent;
        if (CM_Get_Device_ID_List_SizeW(out uint length, "USB", flags) != 0 || length == 0) return false;
        var buffer = new char[length];
        if (CM_Get_Device_ID_ListW("USB", buffer, length, flags) != 0) return false;
        return new string(buffer).Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Any(id => id.Contains(AppleVendor, StringComparison.OrdinalIgnoreCase));
    }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Get_Device_ID_List_SizeW(out uint length, string filter, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Get_Device_ID_ListW(string filter, [Out] char[] buffer, uint length, uint flags);
}
