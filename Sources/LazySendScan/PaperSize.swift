import CoreGraphics

/// The sheet sizes a page is matched against after it is cut out of a photo (`PerspectiveCorrector.matchPaper`).
public enum PaperSize: String, Sendable {
    case letter
    case legal
    case a4
    case idCard

    /// Portrait width × height in inches.
    public var inches: CGSize {
        switch self {
        case .letter: return CGSize(width: 8.5, height: 11)
        case .legal: return CGSize(width: 8.5, height: 14)
        case .a4: return CGSize(width: 8.2677, height: 11.6929)
        case .idCard: return CGSize(width: 2.125, height: 3.370)
        }
    }
}
