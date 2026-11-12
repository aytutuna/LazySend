using System.IO;
using System.Windows;

namespace LazySend.App;

/// <summary>The icon in the notification area: the app keeps running there when its window is closed, so phones can still send.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private DateTime _lastBalloon;

    public TrayIcon(Action open, Action quit)
    {
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("Open Lazy Send", null, (_, _) => open());
        menu.Items.Add("Quit", null, (_, _) => quit());
        using var stream = Application.GetResourceStream(new Uri("pack://application:,,,/LazySend;component/app.ico")).Stream;
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream),
            Text = "Lazy Send",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left) open();
        };
        _icon.BalloonTipClicked += (_, _) => open();
    }

    /// <summary>Shows a balloon, at most one every few seconds so a burst of files does not stack them.</summary>
    public void Balloon(string title, string text, bool force = false)
    {
        if (!force && DateTime.UtcNow - _lastBalloon < TimeSpan.FromSeconds(3)) return;
        _lastBalloon = DateTime.UtcNow;
        _icon.ShowBalloonTip(4000, title, text, System.Windows.Forms.ToolTipIcon.Info);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
