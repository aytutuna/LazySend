using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using LazySend.Core;

namespace LazySend.App.Services;

public enum UsbState
{
    Ready,
    LockedApple,
    NoFileAccess,
}

public sealed record UsbPhoneInfo(string Id, string Name, UsbState State);

/// <summary>A phone's camera roll read through Windows Portable Devices. Use it from one import thread, never the UI thread.</summary>
internal sealed class WpdPhone : IPhoneSource, IDisposable
{
    private static readonly string[] MediaExtensions =
    [
        ".jpg", ".jpeg", ".heic", ".heif", ".png", ".gif", ".webp", ".dng", ".tif", ".tiff", ".bmp",
        ".mov", ".mp4", ".m4v", ".3gp", ".avi", ".mkv", ".webm",
    ];

    private readonly IPortableDevice _device;
    private readonly IPortableDeviceContent _content;
    private readonly IPortableDeviceProperties _properties;
    private readonly IPortableDeviceResources _resources;

    public WpdPhone(UsbPhoneInfo info)
    {
        Id = info.Id;
        Name = info.Name;
        try
        {
            _device = Wpd.Open(info.Id);
            _device.Content(out _content);
            _content.Properties(out _properties);
            _content.Transfer(out _resources);
        }
        catch (COMException e)
        {
            throw Translate(e);
        }
    }

    public string Id { get; }
    public string Name { get; }

    public IReadOnlyList<PhoneMedia> List(CancellationToken cancel)
    {
        var media = new List<PhoneMedia>();
        try
        {
            foreach (string storage in Wpd.Children(_content, Wpd.RootId))
            {
                foreach (string folder in Wpd.Children(_content, storage))
                {
                    cancel.ThrowIfCancellationRequested();
                    string? name = Read(folder)?.Name;
                    if (string.Equals(name, "DCIM", StringComparison.OrdinalIgnoreCase)) Walk(folder, media, cancel);
                    else if (string.Equals(name, "Pictures", StringComparison.OrdinalIgnoreCase)) WalkScreenshots(folder, media, cancel);
                }
            }
        }
        catch (COMException e)
        {
            throw Translate(e);
        }
        return media;
    }

    public Stream Open(PhoneMedia item)
    {
        try
        {
            var key = Wpd.ResourceDefault;
            uint optimal = 0;
            _resources.GetStream(item.ObjectId, ref key, 0, ref optimal, out var stream);
            return new ComStream(stream, this);
        }
        catch (COMException e)
        {
            throw Translate(e);
        }
    }

    public void Dispose()
    {
        try
        {
            _device.Close();
        }
        catch (COMException)
        {
            // Unplugged already.
        }
        Marshal.ReleaseComObject(_resources);
        Marshal.ReleaseComObject(_properties);
        Marshal.ReleaseComObject(_content);
        Marshal.ReleaseComObject(_device);
    }

    private void WalkScreenshots(string pictures, List<PhoneMedia> media, CancellationToken cancel)
    {
        foreach (string child in Wpd.Children(_content, pictures))
        {
            if (string.Equals(Read(child)?.Name, "Screenshots", StringComparison.OrdinalIgnoreCase)) Walk(child, media, cancel);
        }
    }

    private void Walk(string folder, List<PhoneMedia> media, CancellationToken cancel)
    {
        foreach (string id in Wpd.Children(_content, folder))
        {
            cancel.ThrowIfCancellationRequested();
            if (Read(id) is not { } entry || entry.Name.StartsWith('.')) continue;
            if (entry.IsFolder) Walk(id, media, cancel);
            else if (entry.Media is { } item) media.Add(item with { ObjectId = id });
        }
    }

    private sealed record Entry(string Name, bool IsFolder, PhoneMedia? Media);

    private Entry? Read(string objectId)
    {
        var keys = Wpd.NewKeys();
        foreach (var key in new[] { Wpd.ObjectName, Wpd.OriginalFileName, Wpd.PersistentId, Wpd.ContentType, Wpd.Size, Wpd.DateCreated, Wpd.DateModified })
        {
            var copy = key;
            keys.Add(ref copy);
        }
        _properties.GetValues(objectId, keys, out var values);
        try
        {
            string name = Wpd.GetString(values, Wpd.OriginalFileName) ?? Wpd.GetString(values, Wpd.ObjectName) ?? "";
            var type = Wpd.GetGuid(values, Wpd.ContentType);
            bool folder = type == Wpd.FolderType || type == Wpd.FunctionalObjectType;
            if (folder) return new Entry(name, true, null);
            if (!MediaExtensions.Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase)) return new Entry(name, false, null);
            // The time zone of these dates is the device's, which is taken to be this computer's.
            var date = Wpd.GetDate(values, Wpd.DateModified) ?? Wpd.GetDate(values, Wpd.DateCreated) ?? DateTime.Now;
            string persistent = Wpd.GetString(values, Wpd.PersistentId) ?? objectId;
            return new Entry(name, false, new PhoneMedia(objectId, persistent, name, Wpd.GetSize(values) ?? 0, new DateTimeOffset(DateTime.SpecifyKind(date, DateTimeKind.Local))));
        }
        finally
        {
            Marshal.ReleaseComObject(values);
            Marshal.ReleaseComObject(keys);
        }
    }

    // E_FAIL-style codes also come from a phone that is still there, so a failure counts as unplugged only when the phone has left the list.
    private Exception Translate(COMException e)
    {
        bool gone = false;
        try
        {
            var manager = Wpd.NewManager();
            gone = !Wpd.DeviceIds(manager).Contains(Id, StringComparer.OrdinalIgnoreCase);
            Marshal.ReleaseComObject(manager);
        }
        catch (COMException)
        {
            gone = true;
        }
        return gone || WpdDevices.IsGone(e.HResult)
            ? new PhoneGoneException($"{Name} was unplugged or locked.", e)
            : new IOException(e.Message, e);
    }

    private sealed class ComStream(IStream stream, WpdPhone owner) : Stream
    {
        private readonly IntPtr _read = Marshal.AllocCoTaskMem(sizeof(int));

        public override int Read(byte[] buffer, int offset, int count)
        {
            byte[] target = offset == 0 ? buffer : new byte[count];
            try
            {
                stream.Read(target, count, _read);
            }
            catch (COMException e)
            {
                throw owner.Translate(e);
            }
            int read = Marshal.ReadInt32(_read);
            if (offset != 0) Buffer.BlockCopy(target, 0, buffer, offset, read);
            return read;
        }

        protected override void Dispose(bool disposing)
        {
            Marshal.FreeCoTaskMem(_read);
            Marshal.ReleaseComObject(stream);
            base.Dispose(disposing);
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}

internal static class WpdDevices
{
    // Not connected, no such device, device removed, RPC server unavailable or disconnected.
    private static readonly int[] GoneCodes = [unchecked((int)0x8007048F), unchecked((int)0x80070037), unchecked((int)0x80070651), unchecked((int)0x800706BA), unchecked((int)0x80010108)];

    public static bool IsGone(int hresult) => GoneCodes.Contains(hresult);

    /// <summary>Every portable device Windows lists, each opened once to see whether the phone lets the PC in.</summary>
    public static List<UsbPhoneInfo> Scan()
    {
        var manager = Wpd.NewManager();
        var phones = new List<UsbPhoneInfo>();
        try
        {
            foreach (string id in Wpd.DeviceIds(manager))
            {
                string name = Wpd.Text((System.Text.StringBuilder? text, ref uint length) => manager.GetDeviceFriendlyName(id, text, ref length));
                string maker = Wpd.Text((System.Text.StringBuilder? text, ref uint length) => manager.GetDeviceManufacturer(id, text, ref length));
                bool apple = maker.Contains("Apple", StringComparison.OrdinalIgnoreCase) || name.Contains("iPhone", StringComparison.OrdinalIgnoreCase);
                phones.Add(new UsbPhoneInfo(id, name.Length > 0 ? name : "Phone", Probe(id, apple)));
            }
        }
        finally
        {
            Marshal.ReleaseComObject(manager);
        }
        return phones;
    }

    private static UsbState Probe(string id, bool apple)
    {
        try
        {
            var device = Wpd.Open(id);
            try
            {
                device.Content(out var content);
                bool any = Wpd.Children(content, Wpd.RootId).Count > 0;
                Marshal.ReleaseComObject(content);
                return any ? UsbState.Ready : apple ? UsbState.LockedApple : UsbState.NoFileAccess;
            }
            finally
            {
                device.Close();
                Marshal.ReleaseComObject(device);
            }
        }
        catch (COMException)
        {
            return apple ? UsbState.LockedApple : UsbState.NoFileAccess;
        }
    }
}
