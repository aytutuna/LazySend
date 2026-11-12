using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LazySend.Core;

/// <summary>One address of an interface and the length of its subnet's prefix.</summary>
public sealed record LocalSubnet(IPAddress Address, int PrefixLength)
{
    public bool Contains(IPAddress address)
    {
        var a = Normalize(address);
        var b = Normalize(Address);
        if (a.AddressFamily != b.AddressFamily) return false;
        byte[] x = a.GetAddressBytes(), y = b.GetAddressBytes();
        int bits = Math.Clamp(PrefixLength, 0, x.Length * 8);
        for (int i = 0; i < x.Length && bits > 0; i++, bits -= 8)
        {
            int mask = bits >= 8 ? 0xFF : (0xFF << (8 - bits)) & 0xFF;
            if ((x[i] & mask) != (y[i] & mask)) return false;
        }
        return true;
    }

    internal static IPAddress Normalize(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
}

/// <summary>
/// The computer's addresses for the pairing code and the peers the server answers. Every interface
/// that is up counts, whatever its type: an iPhone's Personal Hotspot over USB (172.20.10.x) and
/// Android USB tethering (usually 192.168.42.x) show up as ordinary Ethernet adapters.
/// </summary>
public static class LocalNetworks
{
    private static readonly TimeSpan CacheTime = TimeSpan.FromSeconds(10);
    private static readonly object Gate = new();
    private static DateTime _read;
    private static IReadOnlyList<LocalSubnet> _cached = [];

    /// <summary>The unicast addresses of every interface that is up, loopback and IPv6 link-local ones left out.</summary>
    public static IReadOnlyList<LocalSubnet> Subnets()
    {
        var found = new List<LocalSubnet>();
        try
        {
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily == AddressFamily.InterNetworkV6 && (address.IsIPv6LinkLocal || address.IsIPv6Multicast)) continue;
                    if (address.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)) continue;
                    if (!found.Any(f => f.Address.Equals(address))) found.Add(new LocalSubnet(address, unicast.PrefixLength));
                }
            }
        }
        catch (NetworkInformationException)
        {
            // Nothing to list while the network stack is changing.
        }
        return found;
    }

    /// <summary>
    /// The addresses for a pairing code, at most <see cref="PairingUri.MaxAddresses"/>: IPv4 first, then
    /// IPv6, and self-assigned 169.254.x.x addresses (nothing to reach them with unless the phone has one too) last.
    /// </summary>
    public static IReadOnlyList<string> PairingAddresses() => PairingAddresses(Subnets());

    internal static IReadOnlyList<string> PairingAddresses(IEnumerable<LocalSubnet> subnets) =>
        [.. subnets.Select(s => s.Address)
                   .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? (IsSelfAssigned(a) ? 1 : 0) : 2)
                   .Take(PairingUri.MaxAddresses)
                   .Select(a => a.ToString())];

    /// <summary>
    /// Whether a connection from <paramref name="remote"/> is answered: from this computer, a private,
    /// link-local, shared (100.64.0.0/10) or unique-local address, or one in the subnet of an address
    /// of this computer.
    /// </summary>
    public static bool IsAllowedPeer(IPAddress remote)
    {
        if (IsLocalAddress(remote)) return true;
        IReadOnlyList<LocalSubnet> subnets;
        lock (Gate)
        {
            if (DateTime.UtcNow - _read > CacheTime)
            {
                _cached = Subnets();
                _read = DateTime.UtcNow;
            }
            subnets = _cached;
        }
        return subnets.Any(s => s.Contains(remote));
    }

    internal static bool IsLocalAddress(IPAddress remote)
    {
        var address = LocalSubnet.Normalize(remote);
        if (IPAddress.IsLoopback(address)) return true;
        byte[] b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return b[0] == 10
                   || (b[0] == 172 && (b[1] & 0xF0) == 16)
                   || (b[0] == 192 && b[1] == 168)
                   || (b[0] == 169 && b[1] == 254)
                   || (b[0] == 100 && (b[1] & 0xC0) == 64);
        }
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFE) == 0xFC;
        }
        return false;
    }

    private static bool IsSelfAssigned(IPAddress address)
    {
        byte[] b = address.GetAddressBytes();
        return b[0] == 169 && b[1] == 254;
    }
}
