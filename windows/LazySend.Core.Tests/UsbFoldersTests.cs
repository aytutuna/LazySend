using LazySend.Core;

namespace LazySend.Core.Tests;

public sealed class UsbFoldersTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "lazysend-usbfolders-" + Guid.NewGuid().ToString("N"));
    private readonly List<PairedDevice> _paired = [];

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, true);
    }

    private string FilePath => Path.Combine(_dir, "usb-folders.json");

    private UsbFolders Folders() => new(FilePath, () => _paired);

    private void Pair(string id, string name, string platform) =>
        _paired.Add(new PairedDevice { Id = id, Name = name, Platform = platform });

    [Fact]
    public void OnePairedPhoneOfTheSameKindGivesItsFolder()
    {
        Pair("phone-ios-0001", "Ada's iPhone", "ios");
        Pair("phone-and-0001", "Pixel", "android");

        Assert.Equal("Ada's iPhone", Folders().Resolve("usb#iphone", "Apple iPhone", apple: true).Name);
        Assert.Equal("Pixel", Folders().Resolve("usb#pixel", "Pixel 8", apple: false).Name);
    }

    [Fact]
    public void RenamingThePairedPhoneIsFollowed()
    {
        Pair("phone-ios-0001", "Ada's iPhone", "ios");
        var folders = Folders();
        folders.Resolve("usb#iphone", "Apple iPhone", true);

        _paired[0].Name = "Ada's new iPhone";

        Assert.Equal("Ada's new iPhone", folders.Resolve("usb#iphone", "Apple iPhone", true).Name);
    }

    [Fact]
    public void SeveralCandidatesAreAskedAboutOnce()
    {
        Pair("phone-ios-0001", "Ada's iPhone", "ios");
        Pair("phone-ios-0002", "Bo's iPhone", "ios");
        var folders = Folders();

        var ask = folders.Resolve("usb#iphone", "Apple iPhone", true);

        Assert.Null(ask.Name);
        Assert.Equal(2, ask.Choose.Count);
        folders.Choose("usb#iphone", "Apple iPhone", _paired[1]);
        Assert.Equal("Bo's iPhone", Folders().Resolve("usb#iphone", "Apple iPhone", true).Name);
    }

    [Fact]
    public void WithNoPairedPhoneTheUsbNameIsUsedAndASecondDeviceGetsASuffix()
    {
        var folders = Folders();

        string first = folders.Resolve("usb#one", "Apple iPhone", true).Name!;
        string second = folders.Resolve("usb#two", "Apple iPhone", true).Name!;

        Assert.Equal("Apple iPhone", first);
        Assert.StartsWith("Apple iPhone (", second);
        Assert.Equal(first, folders.Resolve("usb#one", "Apple iPhone", true).Name);
        Assert.Equal(second, Folders().Resolve("usb#two", "Apple iPhone", true).Name);
    }

    [Fact]
    public void ALaterPairingTakesOverFromTheUsbName()
    {
        var folders = Folders();
        Assert.Equal("Apple iPhone", folders.Resolve("usb#one", "Apple iPhone", true).Name);

        Pair("phone-ios-0001", "Ada's iPhone", "ios");

        Assert.Equal("Ada's iPhone", folders.Resolve("usb#one", "Apple iPhone", true).Name);
    }

    [Fact]
    public void AFolderOfItsOwnChosenOverPairedPhonesStays()
    {
        Pair("phone-ios-0001", "Ada's iPhone", "ios");
        Pair("phone-ios-0002", "Bo's iPhone", "ios");
        var folders = Folders();
        folders.Choose("usb#iphone", "Apple iPhone", null);

        Assert.Equal("Apple iPhone", Folders().Resolve("usb#iphone", "Apple iPhone", true).Name);
    }

    [Fact]
    public void ARemovedPhoneIsNotRemembered()
    {
        Pair("phone-ios-0001", "Ada's iPhone", "ios");
        var folders = Folders();
        folders.Resolve("usb#iphone", "Apple iPhone", true);

        _paired.Clear();

        Assert.Equal("Apple iPhone", folders.Resolve("usb#iphone", "Apple iPhone", true).Name);
    }

    [Fact]
    public void ImportLandsInThePairedPhonesFolderAndMatchesWhatWifiSent()
    {
        string root = Path.Combine(_dir, "received");
        var importer = new PhoneImporter(new GalleryIndex(Path.Combine(_dir, "index")), () => root);
        var date = new DateTimeOffset(2025, 5, 10, 12, 0, 0, TimeSpan.Zero);
        string month = Path.Combine(root, "Ada's iPhone", "Gallery", date.ToLocalTime().ToString("yyyy-MM"));
        Directory.CreateDirectory(month);
        File.WriteAllBytes(Path.Combine(month, "IMG_0001.JPG"), new byte[500]);
        var phone = new Phone(("IMG_0001.JPG", 500), ("IMG_0002.JPG", 700));

        var result = importer.Run(phone, "Ada's iPhone", null, default);

        Assert.Equal(1, result.Imported);
        Assert.Equal(1, result.Skipped);
        Assert.True(File.Exists(Path.Combine(month, "IMG_0002.JPG")));
        Assert.False(Directory.Exists(Path.Combine(root, "Apple iPhone")));
    }

    private sealed class Phone(params (string Name, int Size)[] items) : IPhoneSource
    {
        public string Id => "usb#iphone";
        public string Name => "Apple iPhone";

        public IReadOnlyList<PhoneMedia> List(CancellationToken cancel, IProgress<int> found) =>
            [.. items.Select((x, i) => new PhoneMedia("o" + i, "p" + i, x.Name, x.Size, new DateTimeOffset(2025, 5, 10, 12, 0, 0, TimeSpan.Zero)))];

        public Stream Open(PhoneMedia item) => new MemoryStream(new byte[item.Size]);

        public void Dispose()
        {
        }
    }
}
