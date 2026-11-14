using System.IO;
using System.Windows.Threading;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

/// <summary>This PC as a guest of other computers: finding them, and sending to them.</summary>
public sealed partial class AppModel
{
    private readonly WindowsDnsSdBrowser _browser = new();
    private readonly SemaphoreSlim _sendLanes = new(2);

    private void StartComputers()
    {
        Guest.Connector.Announced = AnnouncedAsync;
        Guest.Receiver.TextReceived += (_, item) => _ui.BeginInvoke(() => AddReceivedText(item));
        Guest.Receiver.FileReceived += (_, file) => _ui.BeginInvoke(() => AddReceivedFile(file));
        Guest.Receiver.Failed += (_, text) => _ui.BeginInvoke(() => Notice?.Invoke(this, text));
        Guest.Forgotten += (_, name) => _ui.BeginInvoke(() => Notice?.Invoke(this, $"{name} no longer recognizes this PC. Connect to it again to send to it."));
        Guest.ReachabilityChanged += (_, _) => _ui.BeginInvoke(UpdateLastSeen);
        Guest.Hosts.Changed += (_, _) => _ui.BeginInvoke(RefreshPhones);
        Guest.Start();
    }

    /// <summary>The other computers running Lazy Send on the network, this one left out.</summary>
    public async Task<IReadOnlyList<NearbyHost>> FindComputersAsync(CancellationToken cancellation)
    {
        var found = await _browser.FindAsync(TimeSpan.FromSeconds(3), cancellation).ConfigureAwait(false);
        return [.. found.Where(h => h.Id != Service.Devices.DesktopId)];
    }

    private async Task<NearbyHost?> AnnouncedAsync(string hostId, CancellationToken cancellation)
    {
        var found = await _browser.FindAsync(TimeSpan.FromSeconds(2), cancellation).ConfigureAwait(false);
        return found.FirstOrDefault(h => h.Id == hostId);
    }

    /// <summary>Selects the computer with this id in the list, once it is there.</summary>
    public void SelectComputer(string id) => SelectPhone(Phones.FirstOrDefault(p => p.Id == id));

    private int SendFilesToComputer(PhoneRow computer, IEnumerable<string> paths)
    {
        int started = 0;
        string? problem = null;
        foreach (string path in paths)
        {
            if (Directory.Exists(path))
            {
                problem = "Folders cannot be sent yet. Send the files in them, or zip the folder first.";
                continue;
            }
            if (!File.Exists(path))
            {
                problem = $"{System.IO.Path.GetFileName(path)} is not there any more.";
                continue;
            }
            var info = new FileInfo(path);
            SendToComputer(computer, TimelineKind.File, null, path, (stop, progress) => Guest.SendFileAsync(computer.Id, path, progress, stop), info.Length);
            started++;
        }
        if (problem is not null) Notice?.Invoke(this, problem);
        return started;
    }

    /// <summary>Adds a row for what is being sent and runs <paramref name="send"/>, two at a time; the row says how it went.</summary>
    private void SendToComputer(PhoneRow computer, TimelineKind kind, string? text, string? path,
                                Func<CancellationToken, IProgress<long>, Task> send, long size = 0)
    {
        var stop = new CancellationTokenSource();
        var row = new TimelineItem(kind, true, computer.Id, computer.Name, DateTimeOffset.UtcNow) { Text = text, Path = path, SendStop = stop };
        row.Heading = kind switch
        {
            TimelineKind.File => System.IO.Path.GetFileName(path) ?? "File",
            TimelineKind.Link => $"Link to {computer.Name}",
            _ => $"Text to {computer.Name}",
        };
        string sizeText = kind == TimelineKind.File ? LinkDetector.FormatSize(size) + ", " : "";
        row.CanCancel = true;
        row.Detail = $"{sizeText}Waiting to send, {Stamp(row.Time)}";
        Push(row);
        if (path is not null) LoadThumbnail(row, path, size);
        // Created here, on the UI thread, so its reports come back to it.
        var progress = new Progress<long>(sent =>
        {
            if (row.CanCancel && size > 0) row.Detail = $"{sizeText}Sending, {sent * 100 / size}%, {Stamp(row.Time)}";
        });
        _ = Task.Run(async () =>
        {
            string status;
            try
            {
                await _sendLanes.WaitAsync(stop.Token).ConfigureAwait(false);
                try
                {
                    await _ui.BeginInvoke(() => row.Detail = $"{sizeText}Sending, {Stamp(row.Time)}");
                    await send(stop.Token, progress).ConfigureAwait(false);
                    status = $"Sent to {computer.Name}";
                }
                finally
                {
                    _sendLanes.Release();
                }
            }
            catch (OperationCanceledException)
            {
                status = "Cancelled";
            }
            catch (Exception e)
            {
                status = $"Not sent: {e.Message}";
            }
            _ = _ui.BeginInvoke(() =>
            {
                row.CanCancel = false;
                row.Detail = $"{sizeText}{status}, {Stamp(row.Time)}";
                stop.Dispose();
            });
        });
    }
}
