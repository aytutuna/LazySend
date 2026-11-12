using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace LazySend.Core;

public sealed record PhoneMedia(string ObjectId, string PersistentId, string Name, long Size, DateTimeOffset Date);

/// <summary>A phone's camera roll as the importer sees it. Reads block; the caller runs them off the UI thread.</summary>
public interface IPhoneSource : IDisposable
{
    /// <summary>Stable for one phone across plugs; the import index is keyed by it.</summary>
    string Id { get; }

    string Name { get; }

    IReadOnlyList<PhoneMedia> List(CancellationToken cancel);

    /// <summary>Throws <see cref="PhoneGoneException"/> when the phone is gone and <see cref="IOException"/> when only this item cannot be read.</summary>
    Stream Open(PhoneMedia item);
}

public sealed class PhoneGoneException(string message, Exception? inner = null) : Exception(message, inner);

public enum ImportOutcome
{
    Finished,
    Stopped,
    Disconnected,
    Failed,
}

public sealed record ImportProgress(int Done, int Total, long Bytes, long TotalBytes);

public sealed record ImportResult(ImportOutcome Outcome, int Imported, int Skipped, int Unreadable, long Bytes, string Folder, string? Message = null);

public sealed class PhoneImporter(GalleryIndex index, Func<string> receiveRoot)
{
    private const int ChunkBytes = 1 << 20;
    private static readonly TimeSpan ProgressEvery = TimeSpan.FromMilliseconds(250);

    private sealed class Unreadable(Exception inner) : Exception(inner.Message, inner);

    public ImportResult Run(IPhoneSource phone, IProgress<ImportProgress>? progress, CancellationToken cancel)
    {
        string gallery = Path.Combine(receiveRoot(), FileNames.Clean(phone.Name, "Phone"), "Gallery");
        string indexKey = "usb-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(phone.Id)))[..32].ToLowerInvariant();
        int imported = 0, skipped = 0, unreadable = 0;
        long bytes = 0, current = 0;
        ImportResult Result(ImportOutcome outcome, string? message = null) => new(outcome, imported, skipped, unreadable, bytes, gallery, message);

        try
        {
            var todo = Plan(phone.List(cancel), gallery, indexKey, ref skipped);
            long totalBytes = todo.Sum(t => t.Item.Size);
            var clock = Stopwatch.StartNew();
            var lastReport = TimeSpan.Zero;
            void Report(bool force)
            {
                if (!force && clock.Elapsed - lastReport < ProgressEvery) return;
                lastReport = clock.Elapsed;
                progress?.Report(new ImportProgress(imported + unreadable, todo.Count, bytes + current, totalBytes));
            }

            Report(true);
            foreach (var (item, directory) in todo)
            {
                cancel.ThrowIfCancellationRequested();
                current = 0;
                try
                {
                    bytes += Copy(phone, item, directory, cancel, copied => { current += copied; Report(false); });
                    imported++;
                    index.Add(indexKey, EntryOf(item));
                }
                catch (Unreadable)
                {
                    unreadable++;
                }
                current = 0;
                Report(true);
            }
            return Result(ImportOutcome.Finished);
        }
        catch (OperationCanceledException)
        {
            return Result(ImportOutcome.Stopped);
        }
        catch (PhoneGoneException e)
        {
            return Result(ImportOutcome.Disconnected, e.Message);
        }
        catch (Exception e)
        {
            return Result(ImportOutcome.Failed, e.Message);
        }
    }

    private List<(PhoneMedia Item, string Directory)> Plan(IReadOnlyList<PhoneMedia> items, string gallery, string indexKey, ref int skipped)
    {
        var todo = new List<(PhoneMedia, string)>();
        foreach (var item in items)
        {
            string entry = EntryOf(item);
            if (index.Contains(indexKey, entry))
            {
                skipped++;
                continue;
            }
            string directory = Path.Combine(gallery, item.Date.ToLocalTime().ToString("yyyy-MM", CultureInfo.InvariantCulture));
            var existing = new FileInfo(Path.Combine(directory, FileNames.Clean(item.Name)));
            if (existing.Exists && existing.Length == item.Size)
            {
                // Already there, for instance sent by the phone app over Wi-Fi.
                index.Add(indexKey, entry);
                skipped++;
                continue;
            }
            todo.Add((item, directory));
        }
        return todo;
    }

    private static string EntryOf(PhoneMedia item) => item.PersistentId + ":" + item.Size.ToString(CultureInfo.InvariantCulture);

    /// <summary>Copies one item through a part file; the bytes written count, since a phone that converts HEIC on the fly lists a different size than it sends.</summary>
    private static long Copy(IPhoneSource phone, PhoneMedia item, string directory, CancellationToken cancel, Action<int> chunk)
    {
        Directory.CreateDirectory(directory);
        string part = Path.Combine(directory, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(item.PersistentId)))[..16].ToLowerInvariant() + ".part");
        long written = 0;
        try
        {
            using (var destination = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 81920))
            {
                using var source = OpenSource(phone, item);
                var buffer = new byte[ChunkBytes];
                while (true)
                {
                    cancel.ThrowIfCancellationRequested();
                    int read;
                    try
                    {
                        read = source.Read(buffer, 0, buffer.Length);
                    }
                    catch (IOException e)
                    {
                        throw new Unreadable(e);
                    }
                    if (read == 0) break;
                    destination.Write(buffer, 0, read);
                    written += read;
                    chunk(read);
                }
            }
            if (item.Size > 0 && (written == 0 || (written != item.Size && !CanBeConverted(item.Name))))
            {
                throw new Unreadable(new IOException($"{item.Name} came to {written} of {item.Size} bytes."));
            }
            string path = Path.Combine(directory, FileNames.Unique(directory, FileNames.Clean(item.Name)));
            File.Move(part, path);
            Inbox.MarkAsDownloaded(path);
            if (item.Date.Year is >= 1980 and <= 2100) File.SetLastWriteTimeUtc(path, item.Date.UtcDateTime);
            return written;
        }
        catch
        {
            try
            {
                File.Delete(part);
            }
            catch (IOException)
            {
                // Left for the next run to overwrite.
            }
            throw;
        }
    }

    // An iPhone set to Automatic sends a JPEG for a HEIC photo, so only those may differ from the listed size.
    private static bool CanBeConverted(string name) =>
        Path.GetExtension(name).ToLowerInvariant() is ".heic" or ".heif";

    private static Stream OpenSource(IPhoneSource phone, PhoneMedia item)
    {
        try
        {
            return phone.Open(item);
        }
        catch (IOException e)
        {
            throw new Unreadable(e);
        }
    }
}
