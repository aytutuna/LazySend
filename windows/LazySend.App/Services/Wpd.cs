using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace LazySend.App.Services;

// Windows Portable Devices, declared by hand for the few calls the camera roll import needs.
// The vtable order of each interface is that of PortableDeviceApi.h and PortableDeviceTypes.h.

[StructLayout(LayoutKind.Sequential)]
internal struct PropertyKey(Guid fmtid, uint pid)
{
    public Guid Fmtid = fmtid;
    public uint Pid = pid;
}

// A PROPVARIANT is 24 bytes on 64-bit Windows; only VT_DATE is read.
[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public double Date;
    [FieldOffset(8)] public long Pointer;
}

[ComImport, Guid("a1567595-4c2f-4574-a6fa-ecef917b9a40"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceManager
{
    [PreserveSig] int GetDevices(IntPtr ids, ref uint count);
    void RefreshDeviceList();
    void GetDeviceFriendlyName([MarshalAs(UnmanagedType.LPWStr)] string id, [In, Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder? name, ref uint length);
    void GetDeviceDescription([MarshalAs(UnmanagedType.LPWStr)] string id, [In, Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder? description, ref uint length);
    void GetDeviceManufacturer([MarshalAs(UnmanagedType.LPWStr)] string id, [In, Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder? manufacturer, ref uint length);
}

[ComImport, Guid("625e2df8-6392-4cf0-9ad1-3cfa5f17775c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDevice
{
    void Open([MarshalAs(UnmanagedType.LPWStr)] string id, IPortableDeviceValues clientInfo);
    void SendCommand(uint flags, IPortableDeviceValues parameters, out IPortableDeviceValues results);
    void Content(out IPortableDeviceContent content);
    void Capabilities(out object capabilities);
    void Cancel();
    void Close();
}

[ComImport, Guid("6a96ed84-7c73-4480-9938-bf5af477d426"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceContent
{
    void EnumObjects(uint flags, [MarshalAs(UnmanagedType.LPWStr)] string parentId, IPortableDeviceValues? filter, out IEnumPortableDeviceObjectIDs objects);
    void Properties(out IPortableDeviceProperties properties);
    void Transfer(out IPortableDeviceResources resources);
}

[ComImport, Guid("10ece955-cf41-4728-bfa0-41eedf1bbf19"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IEnumPortableDeviceObjectIDs
{
    [PreserveSig] int Next(uint count, IntPtr ids, out uint fetched);
}

[ComImport, Guid("7f6d695c-03df-4439-a809-59266beee3a6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceProperties
{
    void GetSupportedProperties([MarshalAs(UnmanagedType.LPWStr)] string objectId, out IPortableDeviceKeyCollection keys);
    void GetPropertyAttributes([MarshalAs(UnmanagedType.LPWStr)] string objectId, ref PropertyKey key, out IPortableDeviceValues attributes);
    void GetValues([MarshalAs(UnmanagedType.LPWStr)] string objectId, IPortableDeviceKeyCollection? keys, out IPortableDeviceValues values);
}

[ComImport, Guid("fd8878ac-d841-4d17-891c-e6829cdb6934"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceResources
{
    void GetSupportedResources([MarshalAs(UnmanagedType.LPWStr)] string objectId, out IPortableDeviceKeyCollection keys);
    void GetResourceAttributes([MarshalAs(UnmanagedType.LPWStr)] string objectId, ref PropertyKey key, out IPortableDeviceValues attributes);
    void GetStream([MarshalAs(UnmanagedType.LPWStr)] string objectId, ref PropertyKey key, uint mode, ref uint optimalBufferSize, out IStream stream);
}

[ComImport, Guid("dada2357-e0ad-492e-98db-dd61c53ba353"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceKeyCollection
{
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key);
    void Add(ref PropertyKey key);
}

[ComImport, Guid("6848f6f2-3155-4f86-b6f5-263eeeab3143"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPortableDeviceValues
{
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key, out PropVariant value);
    void SetValue(ref PropertyKey key, ref PropVariant value);
    void GetValue(ref PropertyKey key, out PropVariant value);
    void SetStringValue(ref PropertyKey key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    void GetStringValue(ref PropertyKey key, [MarshalAs(UnmanagedType.LPWStr)] out string value);
    void SetUnsignedIntegerValue(ref PropertyKey key, uint value);
    void GetUnsignedIntegerValue(ref PropertyKey key, out uint value);
    void SetSignedIntegerValue(ref PropertyKey key, int value);
    void GetSignedIntegerValue(ref PropertyKey key, out int value);
    void SetUnsignedLargeIntegerValue(ref PropertyKey key, ulong value);
    void GetUnsignedLargeIntegerValue(ref PropertyKey key, out ulong value);
}

internal static class Wpd
{
    public const string RootId = "DEVICE";
    public const uint GenericRead = 0x80000000;

    public static readonly PropertyKey ObjectName = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 4);
    public static readonly PropertyKey PersistentId = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 5);
    public static readonly PropertyKey ContentType = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 7);
    public static readonly PropertyKey Size = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 11);
    public static readonly PropertyKey OriginalFileName = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 12);
    public static readonly PropertyKey DateCreated = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 18);
    public static readonly PropertyKey DateModified = new(new Guid("ef6b490d-5cd8-437a-affc-da8b60ee4a3c"), 19);
    public static readonly PropertyKey ResourceDefault = new(new Guid("e81e79be-34f0-41bf-b53f-f1a06ae87842"), 0);

    private static readonly Guid ClientGuid = new("204d9f0c-2292-4080-9f42-40664e70f859");
    public static readonly PropertyKey ClientName = new(ClientGuid, 2);
    public static readonly PropertyKey ClientMajor = new(ClientGuid, 3);
    public static readonly PropertyKey ClientMinor = new(ClientGuid, 4);
    public static readonly PropertyKey ClientRevision = new(ClientGuid, 5);
    public static readonly PropertyKey ClientAccess = new(ClientGuid, 9);

    public static readonly Guid FolderType = new("27e2e392-a111-48e0-ab0c-e17705a05f85");
    public static readonly Guid FunctionalObjectType = new("99ed0160-17ff-4c44-9d98-1d7a6f941921");

    private static readonly Guid ManagerClass = new("0af10cec-2ecd-4b92-9581-34f6ae0637f3");
    private static readonly Guid DeviceClass = new("f7c0039a-4762-488a-b4b3-760ef9a1ba9b");
    private static readonly Guid ValuesClass = new("0c15d503-d017-47ce-9016-7b3f978721cc");
    private static readonly Guid KeysClass = new("de2d022d-2480-43be-97f0-d1fa2cf98f4f");

    public static IPortableDeviceManager NewManager() => Create<IPortableDeviceManager>(ManagerClass);

    // The free-threaded variant, so the objects do not care which thread the import runs on.
    public static IPortableDevice NewDevice() => Create<IPortableDevice>(DeviceClass);

    public static IPortableDeviceKeyCollection NewKeys() => Create<IPortableDeviceKeyCollection>(KeysClass);

    private static T Create<T>(Guid clsid) => (T)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid)!)!;

    /// <summary>Opens a device for reading only; the default read-write access is refused by an iPhone.</summary>
    public static IPortableDevice Open(string deviceId)
    {
        var info = Create<IPortableDeviceValues>(ValuesClass);
        var name = ClientName;
        var major = ClientMajor;
        var minor = ClientMinor;
        var revision = ClientRevision;
        var access = ClientAccess;
        info.SetStringValue(ref name, "Lazy Send");
        info.SetUnsignedIntegerValue(ref major, 1);
        info.SetUnsignedIntegerValue(ref minor, 0);
        info.SetUnsignedIntegerValue(ref revision, 0);
        info.SetUnsignedIntegerValue(ref access, GenericRead);
        var device = NewDevice();
        device.Open(deviceId, info);
        Marshal.ReleaseComObject(info);
        return device;
    }

    public static List<string> DeviceIds(IPortableDeviceManager manager)
    {
        manager.RefreshDeviceList();
        uint count = 0;
        Check(manager.GetDevices(IntPtr.Zero, ref count));
        if (count == 0) return [];
        return TakeStrings(count, buffer => manager.GetDevices(buffer, ref count));
    }

    public delegate void NameCall(StringBuilder? text, ref uint length);

    public static string Text(NameCall call)
    {
        uint length = 0;
        call(null, ref length);
        if (length == 0) return "";
        var text = new StringBuilder((int)length);
        call(text, ref length);
        return text.ToString();
    }

    /// <summary>The ids of a folder's children; the device allocates each string and this frees them.</summary>
    public static List<string> Children(IPortableDeviceContent content, string parentId)
    {
        content.EnumObjects(0, parentId, null, out var objects);
        var ids = new List<string>();
        try
        {
            while (true)
            {
                int hr = 0;
                var batch = TakeStrings(100, buffer => hr = objects.Next(100, buffer, out _));
                ids.AddRange(batch);
                if (hr != 0 || batch.Count == 0) break;
            }
        }
        finally
        {
            Marshal.ReleaseComObject(objects);
        }
        return ids;
    }

    private static List<string> TakeStrings(uint capacity, Func<IntPtr, int> fill)
    {
        IntPtr buffer = Marshal.AllocCoTaskMem((int)capacity * IntPtr.Size);
        for (int i = 0; i < capacity; i++) Marshal.WriteIntPtr(buffer, i * IntPtr.Size, IntPtr.Zero);
        try
        {
            Check(fill(buffer));
            var strings = new List<string>();
            for (int i = 0; i < capacity; i++)
            {
                IntPtr pointer = Marshal.ReadIntPtr(buffer, i * IntPtr.Size);
                if (pointer == IntPtr.Zero) continue;
                strings.Add(Marshal.PtrToStringUni(pointer)!);
                Marshal.FreeCoTaskMem(pointer);
            }
            return strings;
        }
        finally
        {
            Marshal.FreeCoTaskMem(buffer);
        }
    }

    // S_FALSE comes with a short or empty batch and is not an error.
    private static void Check(int hr)
    {
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);

    public static string? GetString(IPortableDeviceValues values, PropertyKey key)
    {
        try
        {
            values.GetStringValue(ref key, out string text);
            return text;
        }
        catch (COMException)
        {
            return null;
        }
    }

    public static long? GetSize(IPortableDeviceValues values)
    {
        var key = Size;
        try
        {
            values.GetUnsignedLargeIntegerValue(ref key, out ulong size);
            return (long)size;
        }
        catch (COMException)
        {
            return null;
        }
    }

    public static Guid? GetGuid(IPortableDeviceValues values, PropertyKey key)
    {
        try
        {
            values.GetValue(ref key, out var value);
            // VT_CLSID: the union holds a pointer to the GUID, which the variant owns.
            var guid = value.Type == 72 ? Marshal.PtrToStructure<Guid>((IntPtr)value.Pointer) : (Guid?)null;
            PropVariantClear(ref value);
            return guid;
        }
        catch (COMException)
        {
            return null;
        }
    }

    public static DateTime? GetDate(IPortableDeviceValues values, PropertyKey key)
    {
        try
        {
            values.GetValue(ref key, out var value);
            var date = value.Type == 7 ? DateTime.FromOADate(value.Date) : (DateTime?)null;
            PropVariantClear(ref value);
            return date;
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            return null;
        }
    }
}
