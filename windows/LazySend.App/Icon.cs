using System.Windows;

namespace LazySend.App;

/// <summary>
/// Attaches a Segoe Fluent Icons glyph to a button, tab or segment without touching its
/// Content, which stays a plain string (code reads and writes button captions as text).
/// The shared styles in Styles/Controls.xaml draw the glyph next to the content.
/// </summary>
public static class Icon
{
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.RegisterAttached(
        "Glyph", typeof(string), typeof(Icon), new FrameworkPropertyMetadata(null));

    /// <summary>
    /// Binding path to the glyph for templates. A path object refers to the property directly;
    /// the "(local:Icon.Glyph)" string form is resolved by name at run time and does not resolve
    /// when the windows are hosted by another executable (test drivers).
    /// </summary>
    public static readonly PropertyPath GlyphPath = new(GlyphProperty);

    public static string? GetGlyph(DependencyObject element) => (string?)element.GetValue(GlyphProperty);

    public static void SetGlyph(DependencyObject element, string? value) => element.SetValue(GlyphProperty, value);
}

/// <summary>
/// The application icon for window title bars. The executable carries the same file for
/// Explorer, the taskbar and Alt+Tab.
/// </summary>
public static class AppIcon
{
    /// <summary>Names the assembly, so it also resolves when the windows are hosted by another executable.</summary>
    private static readonly Uri Source = new("pack://application:,,,/LazySend;component/app.ico");

    private static System.Windows.Media.ImageSource? _image;

    /// <summary>All sizes of the icon; windows pick the ones they need from the frame's decoder.</summary>
    public static System.Windows.Media.ImageSource Image =>
        _image ??= System.Windows.Media.Imaging.BitmapFrame.Create(Source);
}
