using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LazySend.App.Services;

public sealed record InterfaceAddress(int Index, IPAddress Address);

/// <summary>
/// Tells the app when the computer's addresses change (Wi-Fi joined, a USB tether plugged in) and lists the
/// interfaces to advertise on. Every interface that is up counts, USB networking included.
/// </summary>
public sealed class NetworkWatcher : IDisposable
{
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(1.5);

    private readonly object _gate = new();
    private Timer? _timer;

    public NetworkWatcher()
    {
        NetworkChange.NetworkAddressChanged += OnChanged;
        NetworkChange.NetworkAvailabilityChanged += OnChanged;
    }

    public event EventHandler? Changed;

    public static IReadOnlyList<InterfaceAddress> Interfaces()
    {
        var found = new List<InterfaceAddress>();
        try
        {
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var properties = adapter.GetIPProperties();
                if (properties.GetIPv4Properties() is not { } v4) continue;
                foreach (var unicast in properties.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily != AddressFamily.InterNetwork || address.ToString().StartsWith("169.254.", StringComparison.Ordinal)) continue;
                    found.Add(new InterfaceAddress(v4.Index, address));
                }
            }
        }
        catch (NetworkInformationException)
        {
            // Asked again at the next change.
        }
        return found;
    }

    private void OnChanged(object? sender, EventArgs e)
    {
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = new Timer(_ => Changed?.Invoke(this, EventArgs.Empty), null, Settle, Timeout.InfiniteTimeSpan);
        }
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnChanged;
        lock (_gate) _timer?.Dispose();
    }
}
