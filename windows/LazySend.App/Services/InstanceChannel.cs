using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace LazySend.App.Services;

/// <summary>
/// How a second start of the app hands its command line to the first: a JSON array of full file paths, in UTF-8, sent over
/// the named pipe <see cref="PipeName"/> and ended by closing the pipe. An empty array just asks the first window to come
/// forward.
/// </summary>
internal sealed class InstanceChannel : IDisposable
{
    /// <summary>Per session, like the single-instance mutex, so a second session of the same user does not reach the first.</summary>
    public static readonly string PipeName = $"LazySend.Open.{System.Diagnostics.Process.GetCurrentProcess().SessionId}";

    /// <summary>A message larger than this is not read; no command line comes near it.</summary>
    private const int MaxMessageBytes = 1 << 20;
    private readonly TimeSpan _readTimeout;

    private readonly string _pipeName;
    private readonly Action<IReadOnlyList<string>> _opened;
    private readonly CancellationTokenSource _stop = new();

    /// <param name="opened">Called on a pool thread with the paths of each message.</param>
    public InstanceChannel(Action<IReadOnlyList<string>> opened, string? pipeName = null, TimeSpan? readTimeout = null)
    {
        _opened = opened;
        _pipeName = pipeName ?? PipeName;
        _readTimeout = readTimeout ?? TimeSpan.FromSeconds(5);
        _ = Task.Run(ListenAsync);
    }

    public static byte[] Encode(IEnumerable<string> paths) => JsonSerializer.SerializeToUtf8Bytes(paths.ToArray());

    /// <summary>The paths of a message; null when it is not one.</summary>
    public static IReadOnlyList<string>? Decode(ReadOnlySpan<byte> message)
    {
        try
        {
            return JsonSerializer.Deserialize<string[]>(message)?.Where(path => !string.IsNullOrWhiteSpace(path)).ToArray();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Hands the paths to the running instance; false when none answers within <paramref name="timeout"/>.</summary>
    public static bool Send(IEnumerable<string> paths, string? pipeName = null, int timeout = 3000)
    {
        try
        {
            // This process is about to exit, so let the first instance bring its window forward.
            AllowSetForegroundWindow(AnyProcess);
            using var pipe = new NamedPipeClientStream(".", pipeName ?? PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(timeout);
            byte[] message = Encode(paths);
            pipe.Write(message, 0, message.Length);
            return true;
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private const int AnyProcess = -1;

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(int processId);

    private async Task ListenAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(_pipeName, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances,
                                                                 PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(_stop.Token);
                using var message = new MemoryStream();
                var buffer = new byte[4096];
                // A client that connects and says nothing must not hold the listener.
                using var readLimit = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
                readLimit.CancelAfter(_readTimeout);
                int read;
                while ((read = await pipe.ReadAsync(buffer, readLimit.Token)) > 0 && message.Length <= MaxMessageBytes)
                {
                    message.Write(buffer, 0, read);
                }
                if (message.Length <= MaxMessageBytes && Decode(message.ToArray()) is { } paths) _opened(paths);
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException)
            {
                // The client was too slow; listen for the next.
            }
            catch (IOException)
            {
                // A client that went away mid-message; listen for the next.
            }
            catch (UnauthorizedAccessException)
            {
                // The name is taken by a pipe that is not ours; try again later instead of never listening.
                try { await Task.Delay(TimeSpan.FromSeconds(5), _stop.Token); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    public void Dispose() => _stop.Cancel();
}
