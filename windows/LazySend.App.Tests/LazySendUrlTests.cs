using LazySend.App.Services;

namespace LazySend.App.Tests;

public sealed class LazySendUrlTests
{
    [Fact]
    public void AnOpenAddressOnTheCommandLineSendsNothing()
    {
        Assert.Empty(App.FilesOf([@"lazysend:open?file=C%3A%5Cx.pdf", "lazysend://open?file=C%3A%5Cy.pdf", "LAZYSEND:open"]));
    }

    [Fact]
    public void APairingAddressIsNotAFile()
    {
        Assert.True(LazySendUrl.IsAddress("lazysend://pair?v=1&id=abc"));
        Assert.Empty(App.FilesOf(["lazysend://pair?v=1&id=abc"]));
    }

    [Fact]
    public void PathsStillCome()
    {
        Assert.Equal([@"C:\y.txt"], App.FilesOf([@"C:\y.txt", "lazysend://pair?v=1"]));
    }
}
