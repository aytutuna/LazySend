using System.Security.Cryptography;
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
    private readonly CertificateStore _certificates;
    private string _thumbprint;
    private DispatcherTimer? _renewal;

    public AppModel(SendPaths paths, CertificateStore certificates, Dispatcher ui)
    {
        _ui = ui;
        Paths = paths;
        Settings = new AppSettings(paths);
        _certificates = certificates;
        var certificate = certificates.Current();
        _thumbprint = certificate.Thumbprint;
        Service = new LinkService(paths, certificate, new LinkServerOptions { AllowPeer = LocalNetworks.IsAllowedPeer });
        Service.Router.ApprovePairing = (request, match, cancellation) =>
        {
            _ui.BeginInvoke(() => PairingRequested?.Invoke(this, request.PhoneName));
            return Approver?.Invoke(request, match, cancellation) ?? Task.FromResult(false);
        };
        _network.Changed += (_, _) => _ui.BeginInvoke(RefreshNetwork);
    }

    public SendPaths Paths { get; }
    public LinkService Service { get; }
    public LinkRouter Router => Service.Router;
    public AppSettings Settings { get; }

    public int Port { get; private set; }

    public string? StartError { get; private set; }

    /// <summary>Why the computer could not be advertised by name; phones can still use the addresses in the code.</summary>
    public string? AdvertiseProblem { get; private set; }

    public FirewallState Firewall { get; private set; } = FirewallState.Unknown;

    /// <summary>The window that can answer a pairing request sets this while it is open; without it a request is declined.</summary>
    public Func<PairRequest, string, CancellationToken, Task<bool>>? Approver { get; set; }

    public event EventHandler? StatusChanged;

    public event EventHandler? AddressesChanged;

    /// <summary>A phone presented a valid pairing code and waits for an answer; the argument is its name.</summary>
    public event EventHandler<string>? PairingRequested;

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
        StartTimeline();
        StartUsb();
        _renewal = new DispatcherTimer(DispatcherPriority.Background, _ui) { Interval = TimeSpan.FromDays(1) };
        _renewal.Tick += (_, _) => RenewCertificate();
        _renewal.Start();
        StatusChanged?.Invoke(this, EventArgs.Empty);
        ReadFirewall();
    }

    public void ReadFirewall() => Task.Run(() => FirewallReader.Read(Environment.ProcessPath ?? "", Packaging.FirewallTokens)).ContinueWith(read =>
    {
        Firewall = read.Result;
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }, CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.FromCurrentSynchronizationContext());

    /// <summary>A certificate near its end is renewed with the same key; the server then presents the new one.</summary>
    private void RenewCertificate()
    {
        try
        {
            var certificate = _certificates.Current();
            if (certificate.Thumbprint == _thumbprint) return;
            Service.ReplaceCertificate(certificate);
            _thumbprint = certificate.Thumbprint;
        }
        catch (CryptographicException e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not renew the phone link certificate: {e.Message}");
        }
    }

    private void RefreshNetwork()
    {
        Advertise();
        AddressesChanged?.Invoke(this, EventArgs.Empty);
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Advertise()
    {
        foreach (var old in _advertisements) old.Dispose();
        _advertisements.Clear();
        AdvertiseProblem = null;
        if (Port == 0) return;
        string name = Environment.MachineName;
        var txt = Protocol.TxtRecords(Service.Devices.DesktopId, Router.DesktopName());
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
        _renewal?.Stop();
        _usbStop.Cancel();
        _network.Dispose();
        foreach (var advertisement in _advertisements) advertisement.Dispose();
        _advertisements.Clear();
        Service.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
    }
}
