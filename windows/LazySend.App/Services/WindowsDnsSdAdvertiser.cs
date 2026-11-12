using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Net;
using LazySend.Core;

namespace LazySend.App.Services;

/// <summary>
/// Advertises the phone link by DNS-SD through Windows' own mDNS responder (DnsServiceRegister,
/// dnsapi.dll, Windows 10 and later, no administrator rights), on one interface per registration
/// (each active one's), so every interface has its own record. Disposing a registration
/// withdraws it (DnsServiceDeRegister). The completion callbacks run on Windows' threads.
/// </summary>
public sealed class WindowsDnsSdAdvertiser
{
    public IDisposable Register(DnsSdRegistration registration) => Registration.Start(registration);

    private sealed class Registration : IDisposable
    {
        private static readonly ConcurrentDictionary<IntPtr, Registration> Pending = new();
        private static readonly RegisterCompleteCallback Callback = Completed;
        private static readonly IntPtr CallbackPointer = Marshal.GetFunctionPointerForDelegate(Callback);
        private static long _nextContext;

        private readonly IntPtr _context;
        private readonly IntPtr _instance;
        private readonly IntPtr _request;
        private readonly TaskCompletionSource<uint> _registered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<uint> _withdrawn = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _disposed;

        private Registration(IntPtr context, IntPtr instance, IntPtr request)
        {
            _context = context;
            _instance = instance;
            _request = request;
        }

        public static Registration Start(DnsSdRegistration registration)
        {
            string serviceName = $"{registration.InstanceName}.{registration.ServiceType}.local";
            var allocations = new List<IntPtr>();
            IntPtr instance = IntPtr.Zero;
            try
            {
                IntPtr ip4 = IntPtr.Zero;
                if (registration.Address is { AddressFamily: AddressFamily.InterNetwork } address)
                {
                    // IP4_ADDRESS: the address in network byte order.
                    ip4 = Allocate(allocations, 4);
                    Marshal.Copy(address.GetAddressBytes(), 0, ip4, 4);
                }
                int count = registration.Txt.Count;
                IntPtr keys = Allocate(allocations, Math.Max(1, count) * IntPtr.Size);
                IntPtr values = Allocate(allocations, Math.Max(1, count) * IntPtr.Size);
                for (int i = 0; i < count; i++)
                {
                    IntPtr key = Marshal.StringToHGlobalUni(registration.Txt[i].Key);
                    IntPtr value = Marshal.StringToHGlobalUni(registration.Txt[i].Value);
                    allocations.Add(key);
                    allocations.Add(value);
                    Marshal.WriteIntPtr(keys, i * IntPtr.Size, key);
                    Marshal.WriteIntPtr(values, i * IntPtr.Size, value);
                }
                // The instance holds its own copies of the names, address and properties.
                instance = DnsServiceConstructInstance(serviceName, registration.HostName, ip4, IntPtr.Zero,
                                                       (ushort)registration.Port, 0, 0, (uint)count, keys, values);
                if (instance == IntPtr.Zero) throw new InvalidOperationException("Windows could not describe the service to advertise.");
                Marshal.WriteInt32(instance, (int)Marshal.OffsetOf<DnsServiceInstance>(nameof(DnsServiceInstance.InterfaceIndex)),
                                   registration.InterfaceIndex);
            }
            finally
            {
                foreach (var allocation in allocations) Marshal.FreeHGlobal(allocation);
            }

            var context = (IntPtr)Interlocked.Increment(ref _nextContext);
            IntPtr request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>());
            Marshal.StructureToPtr(new DnsServiceRegisterRequest
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = (uint)registration.InterfaceIndex,
                ServiceInstance = instance,
                RegisterCompletionCallback = CallbackPointer,
                QueryContext = context,
                Credentials = IntPtr.Zero,
                UnicastEnabled = 0,
            }, request, fDeleteOld: false);
            var created = new Registration(context, instance, request);
            Pending[context] = created;
            uint status = DnsServiceRegister(request, IntPtr.Zero);
            if (status != DnsRequestPending)
            {
                Pending.TryRemove(context, out _);
                Marshal.FreeHGlobal(request);
                DnsServiceFreeInstance(instance);
                throw new InvalidOperationException($"Windows did not advertise the phone link (DNS-SD error {status}).");
            }
            return created;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            uint status = DnsServiceDeRegister(_request, IntPtr.Zero);
            if (status == DnsRequestPending)
            {
                // The request's memory is freed once Windows has finished with it (or given up).
                _ = _withdrawn.Task.WaitAsync(TimeSpan.FromSeconds(10)).ContinueWith(_ => Free(), TaskScheduler.Default);
            }
            else
            {
                Trace.TraceWarning($"Withdrawing the phone link's advertisement returned {status}.");
                Free();
            }
        }

        private void Free()
        {
            Pending.TryRemove(_context, out _);
            Marshal.FreeHGlobal(_request);
            DnsServiceFreeInstance(_instance);
        }

        /// <summary>Called by Windows when a registration or its withdrawal completed.</summary>
        private static void Completed(uint status, IntPtr context, IntPtr instance)
        {
            try
            {
                if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
                if (!Pending.TryGetValue(context, out var registration)) return;
                if (!registration._registered.TrySetResult(status))
                {
                    registration._withdrawn.TrySetResult(status);
                }
                else if (status != 0)
                {
                    Trace.TraceWarning($"Windows could not advertise the phone link (DNS-SD status {status}).");
                }
            }
            catch (Exception e)
            {
                // Never let an exception reach Windows' thread.
                Trace.TraceError($"DNS-SD completion failed: {e}");
            }
        }
    }

    private const uint DnsQueryRequestVersion1 = 1;
    private const uint DnsRequestPending = 9506;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr RegisterCompletionCallback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void RegisterCompleteCallback(uint status, IntPtr context, IntPtr instance);

    private static IntPtr Allocate(List<IntPtr> allocations, int bytes)
    {
        IntPtr memory = Marshal.AllocHGlobal(bytes);
        allocations.Add(memory);
        return memory;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6,
                                                             ushort port, ushort priority, ushort weight, uint propertiesCount,
                                                             IntPtr keys, IntPtr values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);
}
