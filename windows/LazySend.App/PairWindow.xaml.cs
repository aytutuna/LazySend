using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazySend.App.Services;
using LazySend.Core;

namespace LazySend.App;

/// <summary>
/// The pairing code as a QR with its pairing text and check code, and the question when a phone has
/// presented it. The code is made when the window opens and closes with it. A change of the computer's
/// addresses (a USB tether plugged in) redraws the code with the same token.
/// </summary>
public partial class PairWindow : Window
{
    private readonly AppModel _model;
    private readonly IQrEncoder _qr = new ZXingQrEncoder();
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private TaskCompletionSource<bool>? _answer;
    private string? _pairedName;

    public PairWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        model.Approver = AskAsync;
        model.AddressesChanged += OnAddressesChanged;
        model.StatusChanged += OnStatusChanged;
        model.Service.Router.DevicePaired += OnPaired;
        _tick.Tick += (_, _) => UpdateExpiry();
        Loaded += (_, _) =>
        {
            NewCode();
            _tick.Start();
            model.ReadFirewall();
        };
        Closed += OnClosed;
        UpdateConnection();
    }

    private void NewCode()
    {
        _pairedName = null;
        if (_model.Port == 0)
        {
            ExpiryText.Text = _model.StartError ?? "Lazy Send is not listening for phones.";
            return;
        }
        Render(_model.Service.OpenPairing());
        UpdateExpiry();
    }

    private void Render(PairingUri code)
    {
        string text = code.Format();
        PairingTextBox.Text = text;
        CheckCodeBox.Text = FormatCheckCode(SpkiFingerprint.CheckCode(code.FingerprintBytes ?? []));
        AddressesBox.Text = code.Addresses.Count == 0 ? "No network address found" : string.Join("  ", code.Addresses);
        QrImage.Source = _qr.Encode(text) is { } modules ? Draw(modules) : null;
    }

    private static string FormatCheckCode(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;

    /// <summary>The modules as black on white with a four-module quiet zone, six pixels to a module.</summary>
    internal static BitmapSource Draw(QrModules modules)
    {
        const int Scale = 6, Quiet = 4;
        int side = (modules.Size + 2 * Quiet) * Scale;
        var pixels = new byte[side * side];
        Array.Fill(pixels, (byte)255);
        for (int y = 0; y < modules.Size; y++)
        {
            for (int x = 0; x < modules.Size; x++)
            {
                if (!modules[x, y]) continue;
                for (int dy = 0; dy < Scale; dy++)
                {
                    int row = ((y + Quiet) * Scale + dy) * side + (x + Quiet) * Scale;
                    for (int dx = 0; dx < Scale; dx++) pixels[row + dx] = 0;
                }
            }
        }
        var bitmap = BitmapSource.Create(side, side, 96, 96, PixelFormats.Gray8, null, pixels, side);
        bitmap.Freeze();
        return bitmap;
    }

    private void UpdateExpiry()
    {
        if (_pairedName is not null)
        {
            ExpiryText.Text = $"Paired with {_pairedName}.";
            NewCodeButton.Content = "Another phone";
            NewCodeButton.Visibility = Visibility.Visible;
            return;
        }
        var session = _model.Service.Pairing;
        if (session is null)
        {
            ExpiryText.Text = _model.Router.AwaitingApproval > 0 ? "A phone is waiting for your answer." : "This code has expired or was used.";
            NewCodeButton.Content = "New code";
            NewCodeButton.Visibility = _model.Router.AwaitingApproval > 0 ? Visibility.Collapsed : Visibility.Visible;
            return;
        }
        var left = session.Remaining(DateTimeOffset.UtcNow);
        ExpiryText.Text = $"Scan within {(int)left.TotalMinutes}:{left.Seconds:D2}";
        NewCodeButton.Visibility = Visibility.Collapsed;
    }

    private void OnAddressesChanged(object? sender, EventArgs e)
    {
        if (_model.Service.PairingCode() is { } code) Render(code);
    }

    private void OnStatusChanged(object? sender, EventArgs e) => UpdateConnection();

    private void UpdateConnection()
    {
        var lines = new List<string>();
        if (_model.StartError is { } error) lines.Add(error);
        else lines.Add($"Listening on port {_model.Port}.");
        switch (_model.FirewallVerdict)
        {
            case FirewallVerdict.WillAsk:
                lines.Add("Windows may ask whether Lazy Send can use the network the first time a phone connects. Choose Private networks, then Allow.");
                break;
            case FirewallVerdict.Blocked:
                var rules = _model.Firewall.BlockingRules(Environment.ProcessPath ?? "");
                lines.Add($"Windows Firewall blocks Lazy Send ({string.Join(", ", rules)}). Phones cannot connect until it is allowed under Windows Security, Firewall and network protection, Allow an app through firewall.");
                break;
        }
        if (_model.AdvertiseProblem is not null) lines.Add("Phones cannot find this PC by name; scanning the code still works.");
        ConnectionText.Text = string.Join("\n", lines);
    }

    private void OnPaired(object? sender, PairedDevice device) => Dispatcher.BeginInvoke(() =>
    {
        _pairedName = device.Name;
        UpdateExpiry();
        FooterStatus.Text = $"Paired with {device.Name}.";
    });

    private Task<bool> AskAsync(PairRequest request, CancellationToken cancellation)
    {
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.BeginInvoke(() =>
        {
            _answer = answer;
            string kind = request.Platform.Length > 0 ? $" ({request.Platform})" : "";
            ApprovalText.Text = $"\"{PairedDeviceStore.CleanName(request.PhoneName)}\"{kind} wants to pair with this PC. Allow it only if you just scanned the code yourself.";
            ApprovalCard.Visibility = Visibility.Visible;
            Activate();
        });
        cancellation.Register(() => Dispatcher.BeginInvoke(() => Settle(answer, false)));
        return answer.Task;
    }

    private void Settle(TaskCompletionSource<bool> answer, bool allowed)
    {
        answer.TrySetResult(allowed);
        if (ReferenceEquals(_answer, answer))
        {
            _answer = null;
            ApprovalCard.Visibility = Visibility.Collapsed;
        }
    }

    private void Allow_Click(object sender, RoutedEventArgs e)
    {
        if (_answer is { } answer) Settle(answer, true);
    }

    private void Deny_Click(object sender, RoutedEventArgs e)
    {
        if (_answer is { } answer) Settle(answer, false);
    }

    private void NewCode_Click(object sender, RoutedEventArgs e) => NewCode();

    private void CopyPairingText_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(PairingTextBox.Text);
            FooterStatus.Text = "Pairing text copied.";
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            FooterStatus.Text = "Another program is using the clipboard. Try again.";
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _tick.Stop();
        if (_answer is { } answer) Settle(answer, false);
        _model.Approver = null;
        _model.AddressesChanged -= OnAddressesChanged;
        _model.StatusChanged -= OnStatusChanged;
        _model.Service.Router.DevicePaired -= OnPaired;
        _model.Service.ClosePairing();
    }
}
