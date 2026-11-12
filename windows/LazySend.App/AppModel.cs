using System.Security.Cryptography.X509Certificates;
using System.Windows.Threading;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

/// <summary>
/// The app's state behind the windows: the link service, what is advertised on which interface, the
/// firewall's verdict and the pairing prompt. Events are raised on the UI thread.
/// </summary>
public sealed partial class AppModel : IDisposable
{
    private readonly Dispatcher _ui;
    private readonly NetworkWatcher _network = new();
    private readonly WindowsDnsSdAdvertiser _advertiser = new();
    private readonly List<IDisposable> _advertisements = [];

    public AppModel(SendPaths paths, X509Certificate2 certificate, Dispatcher ui)
    {
        _ui = ui;
        Paths = paths;
        Service = new LinkService(paths, certificate, new LinkServerOptions { AllowPeer = LocalNetworks.IsAllowedPeer });
        Service.Router.ApprovePairing = (request, cancellation) => Approver?.Invoke(request, cancellation) ?? Task.FromResult(false);
        _network.Changed += (_, _) => _ui.BeginInvoke(RefreshNetwork);
    }

    public SendPaths Paths { get; }
    public LinkService Service { get; }
    public LinkRouter Router => Service.Router;

    /// <summary>The port phones connect to; 0 when the server could not start.</summary>
    public int Port { get; private set; }

    /// <summary>Why the server did not start; null while it runs.</summary>
    public string? StartError { get; private set; }

    /// <summary>Why the computer could not be advertised by name; phones can still use the addresses in the code.</summary>
    public string? AdvertiseProblem { get; private set; }

    public FirewallState Firewall { get; private set; } = FirewallState.Unknown;

    /// <summary>The window that can answer a pairing request sets this while it is open; without it a request is declined.</summary>
    public Func<PairRequest, CancellationToken, Task<bool>>? Approver { get; set; }

    /// <summary>The server, the advertisement or the firewall verdict changed.</summary>
    public event EventHandler? StatusChanged;

    /// <summary>The computer's addresses changed: a pairing code shown now is out of date.</summary>
    public event EventHandler? AddressesChanged;

    public FirewallVerdict FirewallVerdict => Port == 0 ? FirewallVerdict.Unknown : Firewall.Verdict(Environment.ProcessPath ?? "", Port);

    public void Start()
    {
        try
        {
            Port = Service.Start(Protocol.DefaultPort);
        }
        catch (System.Net.Sockets.SocketException e)
        {
            StartError = $"Lazy Send could not listen for phones: {e.Message}";
        }
        Advertise();
        StatusChanged?.Invoke(this, EventArgs.Empty);
        ReadFirewall();
    }

    /// <summary>Reads the firewall's rules in the background (it takes a moment) and reports the verdict.</summary>
    public void ReadFirewall() => Task.Run(() => FirewallReader.Read(Environment.ProcessPath ?? "")).ContinueWith(read =>
    {
        Firewall = read.Result;
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }, CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.FromCurrentSynchronizationContext());

    private void RefreshNetwork()
    {
        Advertise();
        AddressesChanged?.Invoke(this, EventArgs.Empty);
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Advertises the service on each interface that is up, in place of what was advertised before.</summary>
    private void Advertise()
    {
        foreach (var old in _advertisements) old.Dispose();
        _advertisements.Clear();
        AdvertiseProblem = null;
        if (Port == 0) return;
        string name = Environment.MachineName;
        List<KeyValuePair<string, string>> txt =
        [
            new(Protocol.TxtVersionKey, Protocol.Version.ToString()),
            new(Protocol.TxtIdKey, Service.Devices.DesktopId),
        ];
        foreach (var network in NetworkWatcher.Interfaces())
        {
            try
            {
                _advertisements.Add(_advertiser.Register(new DnsSdRegistration(name, name + ".local", Port, network.Index, network.Address, txt)));
            }
            catch (InvalidOperationException e)
            {
                AdvertiseProblem = e.Message;
            }
        }
    }

    public void Dispose()
    {
        _network.Dispose();
        foreach (var advertisement in _advertisements) advertisement.Dispose();
        _advertisements.Clear();
        Service.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
    }
}
