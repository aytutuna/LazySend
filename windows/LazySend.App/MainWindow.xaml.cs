using System.Windows;

namespace LazySend.App;

public partial class MainWindow : Window
{
    private readonly AppModel _model;

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        model.StatusChanged += (_, _) => ShowStatus();
        ShowStatus();
    }

    private void ShowStatus() => StatusText.Text = _model.StartError ?? $"Listening for phones on port {_model.Port}.";

    /// <summary>Brings the window forward, from the tray or from a second start.</summary>
    public void ShowAndActivate()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }
}
