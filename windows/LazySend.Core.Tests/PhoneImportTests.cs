using LazySend.Core;

namespace LazySend.Core.Tests;

public sealed class PhoneImportTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "lazysend-usb-" + Guid.NewGuid().ToString("N"));
    private readonly GalleryIndex _index;
    private readonly PhoneImporter _importer;

    public PhoneImportTests()
    {
        _index = new GalleryIndex(Path.Combine(_dir, "index"));
        _importer = new PhoneImporter(_index, () => Path.Combine(_dir, "received"));
    }

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, true);
    }

    private string Gallery => Path.Combine(_dir, "received", "Test iPhone", "Gallery");

    private sealed class FakePhone : IPhoneSource
    {
        public string Id => "usb#vid_05ac&pid_12a8#0001";
        public string Name { get; set; } = "Test iPhone";
        public List<PhoneMedia> Items { get; } = [];
        public Dictionary<string, byte[]> Data { get; } = [];
        public Func<PhoneMedia, Stream, Stream>? Wrap { get; set; }
        public HashSet<string> Unreadable { get; } = [];

        public FakePhone Add(string name, int size, DateTimeOffset date)
        {
            var item = new PhoneMedia("o" + Items.Count, "p" + Items.Count, name, size, date);
            Items.Add(item);
            Data[item.ObjectId] = new Random(Items.Count).GetBytes(size);
            return this;
        }

        public Exception? ListFails { get; set; }

        public IReadOnlyList<PhoneMedia> List(CancellationToken cancel) => ListFails is { } e ? throw e : Items;

        public void Dispose()
        {
        }

        public Stream Open(PhoneMedia item)
        {
            if (Unreadable.Contains(item.ObjectId)) throw new IOException("The phone could not read it.");
            Stream stream = new MemoryStream(Data[item.ObjectId]);
            return Wrap?.Invoke(item, stream) ?? stream;
        }
    }

    private sealed class Breaking(Stream inner, int after, Action trip) : Stream
    {
        private int _read;

        public override int Read(byte[] buffer, int offset, int count)
        {
            int n = inner.Read(buffer, offset, Math.Min(count, 1000));
            _read += n;
            if (_read > after) trip();
            return n;
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

    private static readonly DateTimeOffset May = new(2025, 5, 10, 12, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset June = new(2025, 6, 20, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void CopiesIntoMonthFoldersWithTheFileTime()
    {
        var phone = new FakePhone().Add("IMG_0001.JPG", 3000, May).Add("IMG_0002.MOV", 5000, June);

        var result = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Finished, result.Outcome);
        Assert.Equal(2, result.Imported);
        Assert.Equal(8000, result.Bytes);
        Assert.Equal(Gallery, result.Folder);
        string first = Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"), "IMG_0001.JPG");
        Assert.Equal(phone.Data["o0"], File.ReadAllBytes(first));
        Assert.Equal(May.UtcDateTime, File.GetLastWriteTimeUtc(first));
        Assert.True(File.Exists(Path.Combine(Gallery, June.ToLocalTime().ToString("yyyy-MM"), "IMG_0002.MOV")));
        Assert.Empty(Directory.EnumerateFiles(Gallery, "*.part", SearchOption.AllDirectories));
        if (OperatingSystem.IsWindows()) Assert.Contains("ZoneId=3", File.ReadAllText(first + ":Zone.Identifier"));
    }

    [Fact]
    public void SecondRunSkipsWhatWasImported()
    {
        var phone = new FakePhone().Add("IMG_0001.JPG", 3000, May);
        _importer.Run(phone, null, default);
        File.Delete(Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"), "IMG_0001.JPG"));
        phone.Add("IMG_0002.JPG", 100, May);

        var result = _importer.Run(phone, null, default);

        Assert.Equal(1, result.Imported);
        Assert.Equal(1, result.Skipped);
        Assert.False(File.Exists(Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"), "IMG_0001.JPG")));
    }

    [Fact]
    public void SkipsAFileSentOverWifiWithTheSameNameAndSize()
    {
        string month = Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"));
        Directory.CreateDirectory(month);
        File.WriteAllBytes(Path.Combine(month, "IMG_0001.JPG"), new byte[3000]);
        var phone = new FakePhone().Add("IMG_0001.JPG", 3000, May).Add("IMG_0002.JPG", 4000, May);

        var result = _importer.Run(phone, null, default);

        Assert.Equal(1, result.Imported);
        Assert.Equal(1, result.Skipped);
        Assert.Equal(new byte[3000], File.ReadAllBytes(Path.Combine(month, "IMG_0001.JPG")));
    }

    [Fact]
    public void ASameNameOfAnotherSizeGetsASuffix()
    {
        string month = Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"));
        Directory.CreateDirectory(month);
        File.WriteAllBytes(Path.Combine(month, "IMG_0001.JPG"), new byte[10]);
        var phone = new FakePhone().Add("IMG_0001.JPG", 3000, May);

        _importer.Run(phone, null, default);

        Assert.Equal(3000, new FileInfo(Path.Combine(month, "IMG_0001 (2).JPG")).Length);
        Assert.Equal(10, new FileInfo(Path.Combine(month, "IMG_0001.JPG")).Length);
    }

    [Fact]
    public void StopMidFileKeepsDoneFilesAndTheRerunFinishes()
    {
        var phone = new FakePhone().Add("a.jpg", 2000, May).Add("b.jpg", 9000, May).Add("c.jpg", 2000, May);
        using var cancel = new CancellationTokenSource();
        phone.Wrap = (item, stream) => item.Name == "b.jpg" ? new Breaking(stream, 3000, cancel.Cancel) : stream;

        var stopped = _importer.Run(phone, null, cancel.Token);

        Assert.Equal(ImportOutcome.Stopped, stopped.Outcome);
        Assert.Equal(1, stopped.Imported);
        string month = Path.Combine(Gallery, May.ToLocalTime().ToString("yyyy-MM"));
        Assert.Equal(["a.jpg"], Directory.EnumerateFiles(month).Select(Path.GetFileName));

        phone.Wrap = null;
        var again = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Finished, again.Outcome);
        Assert.Equal(2, again.Imported);
        Assert.Equal(1, again.Skipped);
        Assert.Equal(phone.Data["o1"], File.ReadAllBytes(Path.Combine(month, "b.jpg")));
    }

    [Fact]
    public void AnUnpluggedPhoneIsReportedAndTheRerunPicksUp()
    {
        var phone = new FakePhone().Add("a.jpg", 2000, May).Add("b.jpg", 9000, May);
        phone.Wrap = (item, stream) => item.Name == "b.jpg" ? new Breaking(stream, 3000, () => throw new PhoneGoneException("The phone was unplugged.")) : stream;

        var result = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Disconnected, result.Outcome);
        Assert.Equal("The phone was unplugged.", result.Message);
        Assert.Equal(1, result.Imported);
        Assert.Empty(Directory.EnumerateFiles(Gallery, "*.part", SearchOption.AllDirectories));

        phone.Wrap = null;
        var again = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Finished, again.Outcome);
        Assert.Equal(1, again.Imported);
    }

    [Fact]
    public void AnUnreadableItemIsCountedAndTheRunGoesOn()
    {
        var phone = new FakePhone().Add("a.jpg", 100, May).Add("b.jpg", 100, May).Add("c.jpg", 100, May);
        phone.Unreadable.Add("o1");

        var result = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Finished, result.Outcome);
        Assert.Equal(2, result.Imported);
        Assert.Equal(1, result.Unreadable);
    }

    [Theory]
    [InlineData(typeof(UnauthorizedAccessException))]
    [InlineData(typeof(ArgumentException))]
    [InlineData(typeof(InvalidOperationException))]
    public void AnyOtherFaultEndsTheRunAsFailed(Type fault)
    {
        var phone = new FakePhone().Add("a.jpg", 100, May);
        phone.ListFails = (Exception)Activator.CreateInstance(fault, "no")!;

        var result = _importer.Run(phone, null, default);

        Assert.Equal(ImportOutcome.Failed, result.Outcome);
        Assert.Equal("no", result.Message);
    }

    [Fact]
    public void ProgressEndsAtTheTotals()
    {
        var phone = new FakePhone().Add("a.jpg", 2500000, May).Add("b.jpg", 100, June);
        var seen = new List<ImportProgress>();

        _importer.Run(phone, new Inline(seen.Add), default);

        Assert.Equal(new ImportProgress(0, 2, 0, 2500100), seen[0]);
        Assert.Equal(new ImportProgress(2, 2, 2500100, 2500100), seen[^1]);
    }

    private sealed class Inline(Action<ImportProgress> report) : IProgress<ImportProgress>
    {
        public void Report(ImportProgress value) => report(value);
    }
}

file static class RandomExtensions
{
    public static byte[] GetBytes(this Random random, int length)
    {
        var data = new byte[length];
        random.NextBytes(data);
        return data;
    }
}
