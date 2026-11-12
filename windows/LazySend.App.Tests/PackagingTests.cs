using LazySend.App.Services;

namespace LazySend.App.Tests;

public sealed class PackagingTests
{
    [Fact]
    public void ThePackageCallAnswersTooSmallABufferOnlyInsideAPackage()
    {
        Assert.True(Packaging.IsPackageResult(122));
        Assert.False(Packaging.IsPackageResult(15700)); // APPMODEL_ERROR_NO_PACKAGE
        Assert.False(Packaging.IsPackageResult(0));
    }

    [Fact]
    public void TheTestHostIsNotPackaged() => Assert.False(Packaging.IsPackaged);


    [Fact]
    public void APackagedAppOffersNoSendToShortcut()
    {
        Assert.True(ShellIntegration.SendToAvailable);
        Packaging.IsPackaged = true;
        try
        {
            Assert.False(ShellIntegration.SendToAvailable);
            Assert.False(ShellIntegration.SendToShortcut);
        }
        finally
        {
            Packaging.IsPackaged = false;
        }
    }
}
