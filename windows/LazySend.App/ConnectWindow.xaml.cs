using System.IO;
using System.Windows;
using LazySend.Core;

namespace LazySend.App;

/// <summary>
/// Pairs this PC, as a guest, with another computer running Lazy Send: the computers nearby to pick from and the
/// code the other one shows, or its pasted link. Shows the six digits the other computer must show too, then waits
/// for its user to allow it.
/// </summary>
public partial class ConnectWindow : Window
{
    private readonly AppModel _model;
    private readonly CancellationTokenSource _closing = new();
    private bool _pairing;

    public ConnectWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Loaded += async (_, _) => await LookAsync();
        Closed += (_, _) => _closing.Cancel();
    }

    private async Task LookAsync()
    {
        LookButton.IsEnabled = false;
        LookText.Text = "Looking for computers…";
        IReadOnlyList<NearbyHost> found;
        try
        {
            found = await _model.FindComputersAsync(_closing.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Nearby.ItemsSource = found;
        if (found.Count == 1) Nearby.SelectedIndex = 0;
        LookText.Text = found.Count == 0
            ? "No computer found. Both need to be on the same network, with Lazy Send open. You can still paste a link below."
            : "";
        LookButton.IsEnabled = true;
    }

    private async void Look_Click(object sender, RoutedEventArgs e) => await LookAsync();

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (_pairing) return;
        string input = CodeBox.Text.Trim();
        Func<Action<string>, Task<GuestHost>> pair;
        if (input.StartsWith(PairingUri.Scheme + ":", StringComparison.OrdinalIgnoreCase))
        {
            if (PairingUri.TryParse(input, out var error) is not { } link)
            {
                FooterStatus.Text = error!.Message;
                return;
            }
            pair = show => _model.Guest.PairWithLinkAsync(link, show, _closing.Token);
        }
        else if (Nearby.SelectedItem is not NearbyHost host)
        {
            FooterStatus.Text = "Choose the computer above, or paste its link.";
            return;
        }
        else if (PairingSession.NormalizeShortCode(input) is null)
        {
            FooterStatus.Text = "The code is 8 letters and digits, like 7KQ2-M9XD.";
            return;
        }
        else
        {
            pair = show => _model.Guest.PairWithCodeAsync(host, input, show, _closing.Token);
        }
        await PairAsync(pair);
    }

    private async Task PairAsync(Func<Action<string>, Task<GuestHost>> pair)
    {
        _pairing = true;
        ConnectButton.IsEnabled = false;
        CodeBox.IsEnabled = false;
        Nearby.IsEnabled = false;
        FooterStatus.Text = "Connecting…";
        try
        {
            var host = await pair(match => Dispatcher.BeginInvoke(() =>
            {
                MatchText.Text = PairWindow.FormatCheckCode(match);
                MatchHelp.Text = "Waiting for the other computer. Its screen should show these same digits. Choose Allow there only if they match.";
                MatchCard.Visibility = Visibility.Visible;
                FooterStatus.Text = "Waiting for the other computer to allow it…";
            }));
            _model.SelectComputer(host.Id);
            MatchHelp.Text = $"This PC is connected to {host.Name}. Files and text you send go straight to it, and what it sends arrives here.";
            FooterStatus.Text = $"Connected to {host.Name}.";
            ConnectButton.Visibility = Visibility.Collapsed;
            CloseButton.Style = (Style)FindResource("AccentButtonStyle");
            return;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception e) when (e is IOException or LinkException or InvalidOperationException)
        {
            MatchCard.Visibility = Visibility.Collapsed;
            FooterStatus.Text = e.Message;
        }
        _pairing = false;
        ConnectButton.IsEnabled = true;
        CodeBox.IsEnabled = true;
        Nearby.IsEnabled = true;
    }
}
