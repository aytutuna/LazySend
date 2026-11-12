using LazySend.App.Services;

namespace LazySend.App.Tests;

public sealed class LazySendUrlTests
{
    [Fact]
    public void AnOpenAddressNamesEachFile()
    {
        var files = LazySendUrl.Files(@"lazysend:open?file=C%3A%5Cscans%5Ca%20b.pdf&file=D%3A%5Cc.png");

        Assert.Equal([@"C:\scans\a b.pdf", @"D:\c.png"], files);
    }

    [Fact]
    public void OtherFormsAndRelativePathsGiveNothing()
    {
        Assert.Empty(LazySendUrl.Files("lazysend://pair?v=1&id=abc"));
        Assert.Empty(LazySendUrl.Files("lazysend:open"));
        Assert.Empty(LazySendUrl.Files("lazysend:open?file=notes.txt"));
        Assert.Empty(LazySendUrl.Files(@"C:\x\y.txt"));
    }

    [Fact]
    public void AnAddressOnTheCommandLineIsExpandedToItsFiles()
    {
        var files = App.FilesOf([@"lazysend:open?file=C%3A%5Cx.pdf", @"C:\y.txt", "lazysend://pair?v=1"]);

        Assert.Equal([@"C:\x.pdf", @"C:\y.txt"], files);
    }
}
