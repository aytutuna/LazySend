using System.Windows;
using LazySend.Core;

namespace LazySend.App;

/// <summary>The paired phone a phone on USB belongs to; Phone is null for a folder of its own.</summary>
public sealed record PhoneChoice(PairedDevice? Phone);

public partial class PickPhoneWindow : Window
{
    private sealed record Item(string Label, PairedDevice? Phone);

    public PickPhoneWindow(string usbName, IReadOnlyList<PairedDevice> candidates)
    {
        InitializeComponent();
        Question.Text = $"{usbName} is plugged in. Which of your paired phones is it?";
        Choices.ItemsSource = candidates.Select(p => new Item(p.Name, p)).Append(new Item("None of these, keep it in its own folder", null)).ToList();
        Choices.SelectedIndex = 0;
    }

    public PhoneChoice? Choice { get; private set; }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        if (Choices.SelectedItem is not Item item) return;
        Choice = new PhoneChoice(item.Phone);
        DialogResult = true;
    }
}
