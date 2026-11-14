using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using LazySend.Core;

namespace LazySend.App.Services;

/// <summary>
/// Finds the computers announcing Lazy Send through Windows' own mDNS client (DnsServiceBrowse and
/// DnsServiceResolve, dnsapi.dll, Windows 10 version 2004 and later, no administrator rights): the names are
/// listened for a moment, then each is resolved to its port, addresses and TXT entries. The completion
/// callbacks run on Windows' threads.
/// </summary>
public sealed class WindowsDnsSdBrowser
{
    private static readonly ConcurrentDictionary<IntPtr, Survey> Browsing = new();
    private static readonly ConcurrentDictionary<IntPtr, TaskCompletionSource<Resolved?>> Resolving = new();
    private static readonly BrowseCallback BrowseDelegate = OnBrowseCompleted;
    private static readonly ResolveCallback ResolveDelegate = OnResolveCompleted;
    private static readonly IntPtr BrowsePointer = Marshal.GetFunctionPointerForDelegate(BrowseDelegate);
    private static readonly IntPtr ResolvePointer = Marshal.GetFunctionPointerForDelegate(ResolveDelegate);
    private static long _nextContext;

    private sealed record Resolved(string HostName, int Port, IReadOnlyList<IPAddress> Addresses, IReadOnlyDictionary<string, string> Txt);

    /// <summary>What the browse answers carried: the instance names, and often their SRV, TXT and address records too.</summary>
    private sealed class Survey
    {
        public ConcurrentDictionary<string, byte> Instances { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, (string Target, int Port)> Services { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, string[]> Texts { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, ConcurrentDictionary<IPAddress, byte>> Hosts { get; } = new(StringComparer.OrdinalIgnoreCase);

        public Resolved? Of(string instance)
        {
            if (!Services.TryGetValue(instance, out var service) || !Texts.TryGetValue(instance, out var strings)) return null;
            var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string entry in strings)
            {
                int equals = entry.IndexOf('=');
                if (equals > 0) txt[entry[..equals]] = entry[(equals + 1)..];
            }
            string target = service.Target.TrimEnd('.');
            var addresses = Hosts.TryGetValue(target, out var known) ? known.Keys.ToList() : [];
            return new Resolved(target, service.Port, addresses, txt);
        }
    }

    /// <summary>The computers that answer within <paramref name="listen"/>, one entry per id. Empty when Windows cannot browse.</summary>
    public async Task<IReadOnlyList<NearbyHost>> FindAsync(TimeSpan listen, CancellationToken cancellation)
    {
        var survey = new Survey();
        try
        {
            using (StartBrowse(survey))
            {
                await Task.Delay(listen, cancellation).ConfigureAwait(false);
            }
            string[] names = [.. survey.Instances.Keys];
            var resolved = await Task.WhenAll(names.Select(async name =>
            {
                var found = survey.Of(name) ?? await ResolveAsync(name, cancellation).ConfigureAwait(false);
                if (found is { Addresses.Count: 0 }) found = found with { Addresses = await AddressesOfAsync(found.HostName).ConfigureAwait(false) };
                return found;
            })).ConfigureAwait(false);
            string suffix = $".{Protocol.ServiceType}.local";
            var hosts = new Dictionary<string, NearbyHost>();
            foreach (var (name, found) in names.Zip(resolved))
            {
                if (found is null || !found.Txt.TryGetValue(Protocol.TxtIdKey, out string? id) || !Protocol.IsValidId(id)) continue;
                string label = name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? name[..^suffix.Length] : name;
                string shown = found.Txt.TryGetValue(Protocol.TxtNameKey, out string? n) && n.Length > 0 ? n : label;
                var addresses = found.Addresses.Select(a => a.ToString()).Where(a => !a.Contains('%')).ToList();
                hosts[id] = hosts.TryGetValue(id, out var earlier)
                    ? earlier with { Addresses = HostStore.MergeAddresses(earlier.Addresses, addresses) }
                    : new NearbyHost(id, shown, addresses, found.Port);
            }
            return [.. hosts.Values.OrderBy(h => h.Name, StringComparer.CurrentCultureIgnoreCase)];
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException or InvalidOperationException)
        {
            Trace.TraceWarning($"Could not look for computers on the network: {e.Message}");
            return [];
        }
    }

    private static IDisposable StartBrowse(Survey survey)
    {
        var context = (IntPtr)Interlocked.Increment(ref _nextContext);
        IntPtr query = Marshal.StringToHGlobalUni($"{Protocol.ServiceType}.local");
        IntPtr request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceBrowseRequest>());
        IntPtr cancel = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(cancel, IntPtr.Zero);
        Marshal.StructureToPtr(new DnsServiceBrowseRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = query,
            BrowseCallback = BrowsePointer,
            QueryContext = context,
        }, request, fDeleteOld: false);
        Browsing[context] = survey;
        uint status = DnsServiceBrowse(request, cancel);
        if (status != DnsRequestPending)
        {
            Browsing.TryRemove(context, out _);
            Free();
            throw new InvalidOperationException($"Windows could not browse for computers (DNS-SD error {status}).");
        }
        return new Stop(() =>
        {
            DnsServiceBrowseCancel(cancel);
            Browsing.TryRemove(context, out _);
            Free();
        });

        void Free()
        {
            Marshal.FreeHGlobal(query);
            Marshal.FreeHGlobal(request);
            Marshal.FreeHGlobal(cancel);
        }
    }

    private static async Task<Resolved?> ResolveAsync(string instanceName, CancellationToken cancellation)
    {
        var context = (IntPtr)Interlocked.Increment(ref _nextContext);
        var done = new TaskCompletionSource<Resolved?>(TaskCreationOptions.RunContinuationsAsynchronously);
        IntPtr query = Marshal.StringToHGlobalUni(instanceName);
        IntPtr request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceResolveRequest>());
        IntPtr cancel = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(cancel, IntPtr.Zero);
        Marshal.StructureToPtr(new DnsServiceResolveRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = query,
            ResolveCompletionCallback = ResolvePointer,
            QueryContext = context,
        }, request, fDeleteOld: false);
        Resolving[context] = done;
        try
        {
            if (DnsServiceResolve(request, cancel) != DnsRequestPending) return null;
            try
            {
                return await done.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellation).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                DnsServiceResolveCancel(cancel);
                return null;
            }
        }
        finally
        {
            Resolving.TryRemove(context, out _);
            Marshal.FreeHGlobal(query);
            Marshal.FreeHGlobal(request);
            Marshal.FreeHGlobal(cancel);
        }
    }

    /// <summary>The host name asked of Windows' resolver, which answers .local names through mDNS.</summary>
    private static async Task<IReadOnlyList<IPAddress>> AddressesOfAsync(string hostName)
    {
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            return await Dns.GetHostAddressesAsync(hostName, limit.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is System.Net.Sockets.SocketException or OperationCanceledException)
        {
            return [];
        }
    }

    private static void OnBrowseCompleted(uint status, IntPtr context, IntPtr records)
    {
        try
        {
            if (records == IntPtr.Zero) return;
            try
            {
                if (!Browsing.TryGetValue(context, out var survey)) return;
                for (IntPtr record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record))
                {
                    ushort type = (ushort)Marshal.ReadInt16(record, 2 * IntPtr.Size);
                    uint ttl = (uint)Marshal.ReadInt32(record, 2 * IntPtr.Size + 8);
                    string? owner = Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, IntPtr.Size));
                    if (ttl == 0 || owner is null) continue;
                    // The record's data follows its header.
                    int data = 2 * IntPtr.Size + 16;
                    switch (type)
                    {
                        case DnsTypePtr:
                            if (Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, data)) is { Length: > 0 } name) survey.Instances[name] = 0;
                            break;
                        case DnsTypeSrv:
                            string target = Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, data)) ?? "";
                            survey.Services[owner] = (target, (ushort)Marshal.ReadInt16(record, data + IntPtr.Size + 4));
                            break;
                        case DnsTypeTxt:
                            int count = Marshal.ReadInt32(record, data);
                            survey.Texts[owner] = [.. Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, data + IntPtr.Size + i * IntPtr.Size)) ?? "")];
                            break;
                        case DnsTypeA:
                            var v4 = new byte[4];
                            Marshal.Copy(record + data, v4, 0, 4);
                            survey.Hosts.GetOrAdd(owner, _ => new())[new IPAddress(v4)] = 0;
                            break;
                        case DnsTypeAaaa:
                            var v6 = new byte[16];
                            Marshal.Copy(record + data, v6, 0, 16);
                            if (!new IPAddress(v6).IsIPv6LinkLocal) survey.Hosts.GetOrAdd(owner, _ => new())[new IPAddress(v6)] = 0;
                            break;
                    }
                }
            }
            finally
            {
                DnsRecordListFree(records, 1);
            }
        }
        catch (Exception e)
        {
            // Never let an exception reach Windows' thread.
            Trace.TraceError($"DNS-SD browse callback failed: {e}");
        }
    }

    private static void OnResolveCompleted(uint status, IntPtr context, IntPtr instance)
    {
        try
        {
            if (instance == IntPtr.Zero)
            {
                if (Resolving.TryGetValue(context, out var failed)) failed.TrySetResult(null);
                return;
            }
            try
            {
                var data = Marshal.PtrToStructure<DnsServiceInstance>(instance);
                var addresses = new List<IPAddress>();
                if (data.Ip4Address != IntPtr.Zero)
                {
                    var bytes = new byte[4];
                    Marshal.Copy(data.Ip4Address, bytes, 0, 4);
                    addresses.Add(new IPAddress(bytes));
                }
                if (data.Ip6Address != IntPtr.Zero)
                {
                    var bytes = new byte[16];
                    Marshal.Copy(data.Ip6Address, bytes, 0, 16);
                    // The address is link-local when it has no scope here, and cannot be used from a URL.
                    var ip6 = new IPAddress(bytes);
                    if (!ip6.IsIPv6LinkLocal) addresses.Add(ip6);
                }
                var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < data.PropertyCount; i++)
                {
                    string? key = Marshal.PtrToStringUni(Marshal.ReadIntPtr(data.Keys, i * IntPtr.Size));
                    string? value = Marshal.PtrToStringUni(Marshal.ReadIntPtr(data.Values, i * IntPtr.Size));
                    if (key is not null) txt[key] = value ?? "";
                }
                string host = (Marshal.PtrToStringUni(data.HostName) ?? "").TrimEnd('.');
                if (Resolving.TryGetValue(context, out var done)) done.TrySetResult(new Resolved(host, data.Port, addresses, txt));
            }
            finally
            {
                DnsServiceFreeInstance(instance);
            }
        }
        catch (Exception e)
        {
            Trace.TraceError($"DNS-SD resolve callback failed: {e}");
        }
    }

    private sealed class Stop(Action stop) : IDisposable
    {
        private int _stopped;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _stopped, 1) == 0) stop();
        }
    }

    private const uint DnsRequestPending = 9506;
    private const ushort DnsTypeA = 1;
    private const ushort DnsTypePtr = 12;
    private const ushort DnsTypeTxt = 16;
    private const ushort DnsTypeAaaa = 28;
    private const ushort DnsTypeSrv = 33;

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceBrowseRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr BrowseCallback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceResolveRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr ResolveCompletionCallback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceInstance
    {
        public IntPtr InstanceName;
        public IntPtr HostName;
        public IntPtr Ip4Address;
        public IntPtr Ip6Address;
        public ushort Port;
        public ushort Priority;
        public ushort Weight;
        public uint PropertyCount;
        public IntPtr Keys;
        public IntPtr Values;
        public uint InterfaceIndex;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void BrowseCallback(uint status, IntPtr context, IntPtr records);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void ResolveCallback(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceBrowse(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceBrowseCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceResolve(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceResolveCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsRecordListFree(IntPtr records, int freeType);
}
