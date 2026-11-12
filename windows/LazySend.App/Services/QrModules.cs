namespace LazySend.App.Services;

/// <summary>
/// The modules of a QR code, without its quiet zone: <see cref="Size"/> × <see cref="Size"/>, row
/// by row from the top, true for a dark module.
/// </summary>
public sealed class QrModules
{
    private readonly bool[] _dark;

    public QrModules(int size, bool[] dark)
    {
        if (size <= 0) throw new ArgumentOutOfRangeException(nameof(size), "A QR code has at least one module.");
        if (dark.Length != size * size) throw new ArgumentException($"Expected {size * size} modules, got {dark.Length}.", nameof(dark));
        Size = size;
        _dark = dark;
    }

    public int Size { get; }

    public bool this[int x, int y] => _dark[y * Size + x];
}
