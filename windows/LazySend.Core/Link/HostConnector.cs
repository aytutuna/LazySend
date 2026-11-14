namespace LazySend.Core;

/// <summary>A computer announcing Lazy Send on the network: what its DNS-SD record says.</summary>
public sealed record NearbyHost(string Id, string Name, IReadOnlyList<string> Addresses, int Port);

/// <summary>
/// Finds the address a host answers on right now. The addresses kept for it are tried in turn, the one
/// that worked last first, each checked by the host's <c>hello</c> over TLS pinned to its key; the
/// addresses <c>hello</c> lists replace the kept ones. When none answers, <see cref="Announced"/> may name
/// others.
/// </summary>
public sealed class HostConnector(HostStore hosts, string guestId)
{
    /// <summary>The addresses the host with this id announces on the network now.</summary>
    public Func<string, CancellationToken, Task<IReadOnlyList<string>>>? Announced { get; set; }

    /// <summary>
    /// A client for the host, paired and reachable. Throws <see cref="LinkException"/> with status 401 when the
    /// host no longer knows this computer (or it is not kept here), and <see cref="IOException"/> when no address answers.
    /// </summary>
    public async Task<LinkClient> ConnectAsync(string hostId, CancellationToken cancellation)
    {
        if (hosts.Find(hostId) is not { } host) throw new LinkException(401, ErrorCode.Unauthorized, "This computer is not paired any more.");
        if (hosts.Secret(hostId) is not { } secret || Protocol.DecodeBase64Url(host.Fingerprint) is not { } pin)
        {
            throw new LinkException(401, ErrorCode.Unauthorized, $"The key for {host.Name} cannot be read on this account. Pair it again.");
        }
        var credentials = new Credentials(guestId, secret);
        var tried = new HashSet<string>();
        var known = host.LastAddress is null ? host.Addresses : host.Addresses.Prepend(host.LastAddress);
        if (await TryAsync(known) is { } client) return client;
        if (Announced is not null && await TryAsync(await Announced(hostId, cancellation)) is { } found) return found;
        throw new IOException($"Could not reach {host.Name}. Both computers need to be on the same network.");

        async Task<LinkClient?> TryAsync(IEnumerable<string> addresses)
        {
            foreach (string address in addresses.Where(a => !a.Contains('%') && tried.Add(a)))
            {
                var attempt = new LinkClient(address, host.Port, pin, credentials);
                bool kept = false;
                try
                {
                    var hello = await attempt.HelloAsync(cancellation).ConfigureAwait(false);
                    if (hello.DesktopId != host.Id) throw new IOException("Another computer answered.");
                    string name = PairedDeviceStore.CleanName(hello.DesktopName);
                    hosts.Update(host.Id, h =>
                    {
                        h.LastAddress = address;
                        h.Addresses = HostStore.MergeAddresses(hello.Addresses, h.Addresses);
                        if (name.Length > 0) h.Name = name;
                    });
                    kept = true;
                    return attempt;
                }
                catch (LinkException e) when (e.Status != 401)
                {
                    // Another refusal (a rate limit, say): the next address may still answer.
                }
                catch (IOException)
                {
                }
                finally
                {
                    if (!kept) attempt.Dispose();
                }
            }
            return null;
        }
    }
}
