#if os(iOS)
import CoreGraphics
import LazySendScan
import SwiftUI

/// Where the page is, for a look: the photo with the page's outline, four corners and the middle of each edge to drag, a
/// magnifier while one moves, pinch to zoom for the fine placing. Opened for a shot the page was not found clearly in, and for
/// a page that is cut again from the page stack.
struct CornerEditorView: View {
    let request: CornerRequest
    let onAnswer: @MainActor (CornerAnswer) -> Void

    @State private var model: CornerEditorModel
    @State private var display: CGImage?
    @GestureState private var touching: Bool = false
    @GestureState private var pinching: Bool = false
    /// How far the finger has moved since it came down, which a pinch that starts after it needs to find its anchor.
    @State private var fingerShift: CGSize = .zero
    @State private var shiftAtPinch: CGSize = .zero

    init(request: CornerRequest, onAnswer: @escaping @MainActor (CornerAnswer) -> Void) {
        self.request = request
        self.onAnswer = onAnswer
        _model = State(initialValue: CornerEditorModel(photoWidth: request.photo.width, photoHeight: request.photo.height,
                                                       corners: request.corners))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { (geometry: GeometryProxy) in
                    stage(size: geometry.size)
                }
                // The photo's left is the photo's left whatever the language.
                .environment(\.layoutDirection, .leftToRight)
                footer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Corners")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if request.replacing == nil {
                        // A shot that is left out is a retake: the page still in view can be taken again.
                        Button("Retake") { onAnswer(.cancel) }
                            .accessibilityIdentifier("corners.retake")
                    } else {
                        Button("Cancel") { onAnswer(.cancel) }
                            .accessibilityIdentifier("corners.cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use corners") { onAnswer(.use(model.corners)) }
                        .disabled(!model.canUseCorners)
                        .accessibilityIdentifier("corners.use")
                }
            }
        }
        .task {
            await loadDisplay()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if request.replacing == nil {
                Label("The page was not found clearly.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .accessibilityIdentifier("corners.reason")
            }
            Text("Drag each corner onto a corner of the page.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Reset") {
                model.reset()
            }
            .disabled(!model.canReset)
            .accessibilityHint(Text("Back to the starting corners and zoom"))
            .accessibilityIdentifier("corners.reset")
            Spacer(minLength: 0)
            Button("Use whole photo") {
                onAnswer(.whole)
            }
            .accessibilityIdentifier("corners.whole")
        }
        .buttonStyle(.bordered)
        .padding(16)
    }

    // MARK: The photo and its corners

    private func stage(size: CGSize) -> some View {
        let frame: CGRect = model.shownFrame(in: size)
        let points: [CGPoint] = model.viewCorners(frame: frame)
        let edges: [Int] = model.shownEdges(frame: frame)
        return ZStack {
            Color.black.opacity(0.85)
            if let display {
                Image(decorative: display, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            } else {
                ProgressView()
                    .tint(Color.white)
            }
            CornerOutline(points: points, edges: edges, frame: frame, selected: model.selected, moving: model.dragging)
            ForEach(0..<4, id: \.self) { (index: Int) in
                cornerElement(index, at: points[index])
            }
            ForEach(4..<8, id: \.self) { (index: Int) in
                edgeElement(index, at: model.handlePoint(index, frame: frame))
            }
            if model.showsLoupe, let display {
                loupe(display, frame: frame, fitted: model.fittedFrame(in: size), size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(cornerDrag(frame: frame, size: size))
        .simultaneousGesture(pinch(size: size))
        .onChange(of: touching) { (_: Bool, isDown: Bool) in
            if !isDown { model.touchEnded() }
        }
        .onChange(of: pinching) { (_: Bool, isDown: Bool) in
            if !isDown { model.endPinch() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Page corners"))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { (press: KeyPress) -> KeyPress.Result in
            handleKey(press)
        }
        .accessibilityIdentifier("corners.stage")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let fine: Bool = !press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            model.shift(model.selected, dx: -1, dy: 0, fine: fine)
        case .rightArrow:
            model.shift(model.selected, dx: 1, dy: 0, fine: fine)
        case .upArrow:
            model.shift(model.selected, dx: 0, dy: -1, fine: fine)
        case .downArrow:
            model.shift(model.selected, dx: 0, dy: 1, fine: fine)
        default:
            guard let number = Int(press.characters), (1...4).contains(number) else { return .ignored }
            model.select(number - 1)
        }
        return .handled
    }

    /// Corner `index` for VoiceOver: swipe up moves it outward, down inward.
    private func cornerElement(_ index: Int, at point: CGPoint) -> some View {
        Color.clear
            .frame(width: 44, height: 44)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(model.cornerLabel(index)))
            .accessibilityValue(Text(model.cornerValue(index)))
            .accessibilityHint(Text("Swipe up to move the corner out, down to move it in, or use the actions to move it one way"))
            .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                switch direction {
                case .increment:
                    model.nudge(index, outward: true)
                default:
                    model.nudge(index, outward: false)
                }
            }
            .accessibilityAction(named: Text("Move left")) {
                model.shift(index, dx: -1, dy: 0)
            }
            .accessibilityAction(named: Text("Move right")) {
                model.shift(index, dx: 1, dy: 0)
            }
            .accessibilityAction(named: Text("Move up")) {
                model.shift(index, dx: 0, dy: -1)
            }
            .accessibilityAction(named: Text("Move down")) {
                model.shift(index, dx: 0, dy: 1)
            }
            .accessibilityIdentifier("corner.\(index)")
    }

    /// Edge handle `index` for VoiceOver: swipe up moves the edge outward, down inward.
    private func edgeElement(_ index: Int, at point: CGPoint) -> some View {
        Color.clear
            .frame(width: 44, height: 44)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(model.edgeLabel(index)))
            .accessibilityValue(Text(model.edgeValue(index)))
            .accessibilityHint(Text("Swipe up to move the edge out, down to move it in"))
            .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                switch direction {
                case .increment:
                    model.nudgeEdge(index, outward: true)
                default:
                    model.nudgeEdge(index, outward: false)
                }
            }
            .accessibilityIdentifier("edge.\(index)")
    }

    private func cornerDrag(frame: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { (_: DragGesture.Value, state: inout Bool, _: inout Transaction) in
                state = true
            }
            .onChanged { (value: DragGesture.Value) in
                fingerShift = value.translation
                model.touchMoved(start: value.startLocation, to: value.location, frame: frame, size: size)
            }
    }

    private func pinch(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinching) { (_: MagnifyGesture.Value, state: inout Bool, _: inout Transaction) in
                state = true
            }
            .onChanged { (value: MagnifyGesture.Value) in
                if display == nil { return }
                if !model.isPinching {
                    model.beginPinch()
                    shiftAtPinch = fingerShift
                }
                let anchor = CGPoint(x: value.startLocation.x + fingerShift.width - shiftAtPinch.width,
                                     y: value.startLocation.y + fingerShift.height - shiftAtPinch.height)
                model.pinch(by: value.magnification, around: anchor, size: size)
            }
    }

    /// The magnifier over the moved corner, diagonally away from the page's middle.
    private func loupe(_ image: CGImage, frame: CGRect, fitted: CGRect, size: CGSize) -> some View {
        let center: CGPoint = model.loupeCenter(frame: frame, in: size)
        let offset: CGSize = model.loupeImageOffset(frame: fitted)
        let side: CGFloat = CornerEditorModel.loupeSize
        let zoom: CGFloat = CornerEditorModel.loupeZoom
        return ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                .offset(x: offset.width, y: offset.height)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
        .overlay(LoupeCrosshair().stroke(Color.accentColor, lineWidth: 1))
        .position(center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The photo made at most 4096 pixels long, off the main actor: a 12 MP photo is shown whole, so the
    /// magnifier zooms its own pixels. The corners stay in the photo's pixels whatever size it is shown at.
    private func loadDisplay() async {
        let photo = request.photo
        let shown: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let longSide: Int = max(photo.width, photo.height, 1)
            if longSide <= 4096 {
                return photo.makeCGImage()
            }
            let scale: Double = 4096.0 / Double(longSide)
            let width: Int = max(1, Int(Double(photo.width) * scale))
            let height: Int = max(1, Int(Double(photo.height) * scale))
            return photo.resized(width: width, height: height).makeCGImage()
        }.value
        display = shown
    }
}

/// The page's outline over the photo: the photo outside it dimmed, its edges, and the handles: a circle on
/// each corner and a bar on the middle of each edge in `edges` (the one moved last larger).
private struct CornerOutline: View {
    let points: [CGPoint]
    let edges: [Int]
    let frame: CGRect
    let selected: Int
    let moving: Int?

    var body: some View {
        ZStack {
            Path { (path: inout Path) in
                path.addRect(frame)
                addOutline(&path)
            }
            .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
            Path { (path: inout Path) in
                addOutline(&path)
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2))
            ForEach(0..<4, id: \.self) { (index: Int) in
                handle(index)
            }
            ForEach(edges, id: \.self) { (index: Int) in
                bar(index)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func addOutline(_ path: inout Path) {
        guard points.count == 4 else { return }
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.addLine(to: points[3])
        path.closeSubpath()
    }

    private func handle(_ index: Int) -> some View {
        let big: Bool = index == selected || index == moving
        let side: CGFloat = big ? 26 : 20
        return Circle()
            .fill(Color.accentColor.opacity(0.35))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: big ? 3 : 2))
            .frame(width: side, height: side)
            .position(points[index])
    }

    private func bar(_ index: Int) -> some View {
        let a: CGPoint = points[index & 3]
        let b: CGPoint = points[(index + 1) & 3]
        let angle: Double = atan2(Double(b.y - a.y), Double(b.x - a.x))
        let big: Bool = index == selected || index == moving
        let width: CGFloat = big ? 28 : 22
        let height: CGFloat = big ? 11 : 8
        return Capsule()
            .fill(Color.accentColor.opacity(0.35))
            .overlay(Capsule().strokeBorder(Color.white, lineWidth: big ? 3 : 2))
            .frame(width: width, height: height)
            .rotationEffect(.radians(angle))
            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// The magnifier's cross at its center.
private struct LoupeCrosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: middle.x, y: middle.y - 14))
        path.addLine(to: CGPoint(x: middle.x, y: middle.y + 14))
        path.move(to: CGPoint(x: middle.x - 14, y: middle.y))
        path.addLine(to: CGPoint(x: middle.x + 14, y: middle.y))
        return path
    }
}
#endif
