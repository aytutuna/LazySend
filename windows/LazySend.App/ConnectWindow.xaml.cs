using System.Windows;
using LazySend.Core;

namespace LazySend.App;

/// <summary>
/// Pairs this PC, as a guest, with another computer running Lazy Send: the computers nearby to pick from and the
/// code the other one shows, or its pasted link. With a code, the six digits worked out here are shown first and
/// the code is sent only once the user says the other computer shows the same; then the other computer's user
/// is asked too.
/// </summary>
public partial class ConnectWindow : Window
{
    private readonly AppModel _model;
    private readonly CancellationTokenSource _closing = new();
    private TaskCompletionSource<bool>? _answer;
    private bool _pairing;

    public ConnectWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Loaded += async (_, _) => await LookAsync();
        Closed += (_, _) =>
        {
            _closing.Cancel();
            _answer?.TrySetResult(false);
        };
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
        Func<Task<GuestHost>> pair;
        if (input.StartsWith(PairingUri.Scheme + ":", StringComparison.OrdinalIgnoreCase))
        {
            if (PairingUri.TryParse(input, out var error) is not { } link)
            {
                FooterStatus.Text = error!.Message;
                return;
            }
            pair = () => _model.Guest.PairWithLinkAsync(link, ShowMatch, _closing.Token);
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
            pair = () => _model.Guest.PairWithCodeAsync(host, input, AskMatchAsync, _closing.Token);
        }
        await PairAsync(pair);
    }

    /// <summary>Shows the digits of a pairing whose fingerprint came in a link, and that the other computer is being asked.</summary>
    private void ShowMatch(string match) => Dispatcher.BeginInvoke(() =>
    {
        MatchText.Text = PairWindow.FormatCheckCode(match);
        MatchHelp.Text = "Waiting for the other computer. Its screen should show these same digits. Choose Allow there only if they match.";
        MatchCard.Visibility = Visibility.Visible;
        FooterStatus.Text = "Waiting for the other computer to allow it…";
    });

    /// <summary>Asks whether the other computer shows these digits next to its code; the code goes out only on yes.</summary>
    private Task<bool> AskMatchAsync(string match)
    {
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.BeginInvoke(() =>
        {
            _answer = answer;
            MatchText.Text = PairWindow.FormatCheckCode(match);
            MatchHelp.Text = "Does the other computer show these same digits under its code? If not, choose No: another computer may be answering, and nothing is sent to it.";
            MatchChoice.Visibility = Visibility.Visible;
            MatchCard.Visibility = Visibility.Visible;
            FooterStatus.Text = "Compare the digits with the other computer.";
        });
        return answer.Task;
    }

    private void Yes_Click(object sender, RoutedEventArgs e) => Answer(true);

    private void No_Click(object sender, RoutedEventArgs e) => Answer(false);

    private void Answer(bool matches)
    {
        if (_answer is not { } answer) return;
        _answer = null;
        MatchChoice.Visibility = Visibility.Collapsed;
        if (matches)
        {
            MatchHelp.Text = "Waiting for the other computer to allow it. Choose Allow there.";
            FooterStatus.Text = "Waiting for the other computer to allow it…";
        }
        answer.TrySetResult(matches);
    }

    private async Task PairAsync(Func<Task<GuestHost>> pair)
    {
        _pairing = true;
        ConnectButton.IsEnabled = false;
        CodeBox.IsEnabled = false;
        Nearby.IsEnabled = false;
        FooterStatus.Text = "Connecting…";
        try
        {
            var host = await pair();
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
        catch (Exception e)
        {
            MatchCard.Visibility = Visibility.Collapsed;
            MatchChoice.Visibility = Visibility.Collapsed;
            FooterStatus.Text = e.Message;
        }
        _pairing = false;
        ConnectButton.IsEnabled = true;
        CodeBox.IsEnabled = true;
        Nearby.IsEnabled = true;
    }
}
