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

    [Fact]
    public void APackageRuleIsRecognisedByThePackagesNameAndPublisher()
    {
        string[] tokens = ["Aytu.LazySend", "sz3y6cn7106ae"];

        Assert.True(FirewallReader.IsPackageRule("@{Aytu.LazySend_1.0.2.0_x64__sz3y6cn7106ae?ms-resource://x} ", tokens));
        Assert.False(FirewallReader.IsPackageRule("@{Aytu.LazyPrint_1.0.0.0_x64__sz3y6cn7106ae?x}", tokens));
        Assert.False(FirewallReader.IsPackageRule("Aytu.LazySend", null));
    }
}
