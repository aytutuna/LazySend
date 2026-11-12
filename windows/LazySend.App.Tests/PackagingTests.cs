using System.IO;
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
    public void TheSendToShortcutStartsTheExeOrThePackagesAlias()
    {
        Assert.Equal(Environment.ProcessPath, ShellIntegration.SendToTarget);
        Packaging.IsPackaged = true;
        try
        {
            Assert.EndsWith(Path.Combine("Microsoft", "WindowsApps", "LazySend.exe"), ShellIntegration.SendToTarget);
        }
        finally
        {
            Packaging.IsPackaged = false;
        }
    }
}
