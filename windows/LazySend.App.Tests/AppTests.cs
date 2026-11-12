using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App.Tests;

public class LinkDetectorTests
{
    [Theory]
    [InlineData("https://alazy.app/send/", true)]
    [InlineData("  http://example.com/a?b=c  ", true)]
    [InlineData("https://example.com and more", false)]
    [InlineData("see https://example.com", false)]
    [InlineData("ftp://example.com", false)]
    [InlineData("file:///c:/windows/system32/calc.exe", false)]
    [InlineData("example.com", false)]
    [InlineData("", false)]
    public void OnlyALoneWebAddressIsALink(string text, bool expected) => Assert.Equal(expected, LinkDetector.IsLink(text));

    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(1023, "1023 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(5L * 1024 * 1024 * 1024, "5 GB")]
    public void SizesAreReadable(long bytes, string expected) => Assert.Equal(expected, LinkDetector.FormatSize(bytes));
}

public class InstanceChannelTests
{
    [Fact]
    public void PathsSurviveTheMessage()
    {
        string[] paths = [@"C:\Users\me\My Photos\a.jpg", @"D:\ü\b.txt"];

        Assert.Equal(paths, InstanceChannel.Decode(InstanceChannel.Encode(paths)));
        Assert.Null(InstanceChannel.Decode("not json"u8));
    }

    [Fact]
    public async Task SecondStartHandsItsFilesToTheFirst()
    {
        string pipe = "LazySend.Test." + Guid.NewGuid().ToString("N");
        var received = new TaskCompletionSource<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(received.SetResult, pipe);

        Assert.True(InstanceChannel.Send([@"C:\a b\c.txt"], pipe));

        Assert.Equal([@"C:\a b\c.txt"], await received.Task.WaitAsync(TimeSpan.FromSeconds(10)));
    }

    [Fact]
    public void FlagsAreNotFiles()
    {
        var files = App.FilesOf([App.MinimizedFlag, @"C:\x\y.txt", ""]);

        Assert.Equal([@"C:\x\y.txt"], files);
    }
}

public class TimelineItemTests
{
    [Fact]
    public void TextRowsCopyAndLongTextIsShortenedForDisplay()
    {
        var item = new TimelineItem(TimelineKind.Text, false, "device-1", "Phone", DateTimeOffset.UtcNow) { Text = new string('a', 5000) };

        Assert.True(item.CanCopy);
        Assert.False(item.CanOpen);
        Assert.Equal(1201, item.Body!.Length);
        Assert.Equal(5000, item.Text!.Length);
    }

    [Fact]
    public void FileRowsOpenAndShowInTheirFolder()
    {
        var item = new TimelineItem(TimelineKind.File, false, "device-1", "Phone", DateTimeOffset.UtcNow) { Path = @"C:\x\a.pdf" };

        Assert.True(item.CanOpen);
        Assert.True(item.CanShowFolder);
        Assert.False(item.CanCopy);
        Assert.True(item.ShowGlyph);
    }
}

public class QrTests
{
    [Fact]
    public void PairingCodeFitsInAQr()
    {
        var code = new PairingUri(Convert.ToHexStringLower(new byte[16]), "Aytu's PC", Protocol.EncodeBase64Url(new byte[32]),
                                  ["192.168.1.5", "172.20.10.2", "192.168.42.129", "fd00::1"], 52734, Protocol.EncodeBase64Url(new byte[16]));

        var modules = new ZXingQrEncoder().Encode(code.Format());

        Assert.NotNull(modules);
        Assert.InRange(modules!.Size, 21, 177);
    }
}

public class InstanceChannelTimeoutTests
{
    [Fact]
    public async Task SilentClientDoesNotStallTheListener()
    {
        string pipe = "LazySend.Test." + Guid.NewGuid().ToString("N");
        var received = new TaskCompletionSource<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(received.SetResult, pipe, TimeSpan.FromMilliseconds(300));
        using var silent = new System.IO.Pipes.NamedPipeClientStream(".", pipe, System.IO.Pipes.PipeDirection.Out);
        silent.Connect(5000);

        Assert.True(InstanceChannel.Send([@"C:\a\b.txt"], pipe, 8000));

        Assert.Equal([@"C:\a\b.txt"], await received.Task.WaitAsync(TimeSpan.FromSeconds(10)));
    }
}
