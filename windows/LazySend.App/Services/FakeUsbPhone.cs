#if DEBUG
using System.IO;
using LazySend.Core;

namespace LazySend.App.Services;

/// <summary>A phone that is not there, for trying the import window; listed only in debug builds when LAZYSEND_FAKE_USB=1.</summary>
internal sealed class FakeUsbPhone : IPhoneSource
{
    public static readonly UsbPhoneInfo Info = new("fake-usb-phone", "Demo iPhone", true, UsbState.Ready);

    public string Id => Info.Id;
    public string Name => Info.Name;

    public IReadOnlyList<PhoneMedia> List(CancellationToken cancel, IProgress<int> found) =>
        [.. Enumerable.Range(1, 60).Select(i => new PhoneMedia($"o{i}", $"p{i}", $"IMG_{i:0000}.JPG", 6_000_000 + i * 1000, DateTimeOffset.Now.AddDays(-i * 9)))];

    public Stream Open(PhoneMedia item) => new SlowStream(item.Size);

    public void Dispose()
    {
    }

    private sealed class SlowStream(long length) : Stream
    {
        private long _left = length;

        public override int Read(byte[] buffer, int offset, int count)
        {
            Thread.Sleep(40);
            int n = (int)Math.Min(Math.Min(_left, count), 400_000);
            _left -= n;
            return n;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
#endif
