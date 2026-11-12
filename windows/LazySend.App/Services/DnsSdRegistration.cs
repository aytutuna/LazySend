using System.Net;
using LazySend.Core;

namespace LazySend.App.Services;

/// <summary>A DNS-SD service to advertise on one interface.</summary>
/// <param name="InstanceName">The service instance's name (the computer's name).</param>
/// <param name="HostName">The host name its address record uses ("AYTU-PC.local").</param>
/// <param name="Address">The interface's IPv4 address for the host record; null for none.</param>
public sealed record DnsSdRegistration(string InstanceName, string HostName, int Port, int InterfaceIndex, IPAddress? Address,
                                       IReadOnlyList<KeyValuePair<string, string>> Txt)
{
    public string ServiceType => Protocol.ServiceType;
}
