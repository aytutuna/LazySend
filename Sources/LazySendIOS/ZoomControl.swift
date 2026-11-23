#if os(iOS)
import SwiftUI
import UIKit

/// The numbers behind the zoom control: where its wheel's ends are, how far a finger moves the zoom, and how a zoom is written.
enum ZoomDial {
    /// How far a finger travels for the zoom to double.
    static let pointsPerDoubling: CGFloat = 90

    /// The wheel goes from the widest lens to the format's top, at most 10x and at most five times the longest lens.
    static func range(stops: [Double], top: Double) -> ClosedRange<Double> {
        let low = stops.first ?? 1
        return low...max(low, min(top, 10, (stops.last ?? 1) * 5))
    }

    /// The zoom a finger that moved `dragged` points to the right of where it began gives; moving left zooms in.
    static func zoom(from start: Double, dragged: CGFloat, in range: ClosedRange<Double>) -> Double {
        min(max(start * pow(2, Double(-dragged / pointsPerDoubling)), range.lowerBound), range.upperBound)
    }

    /// Where `zoom` sits to the right of `current` on the wheel.
    static func offset(of zoom: Double, from current: Double) -> CGFloat {
        CGFloat(log2(zoom / current)) * pointsPerDoubling
    }

    static func crossesStop(from old: Double, to new: Double, stops: [Double]) -> Bool {
        stops.contains { (old < $0 && new >= $0) || (old > $0 && new <= $0) }
    }

    /// The stop after (or before) `zoom`, for the adjustable element; nil past the last one.
    static func step(from zoom: Double, stops: [Double], up: Bool) -> Double? {
        up ? stops.first { $0 > zoom + 0.01 } : stops.last { $0 < zoom - 0.01 }
    }

    /// The active button reads "1.4×"; the others just ".5" or "2".
    static func label(_ value: Double, active: Bool, locale: Locale = .current) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        if active { return text + "×" }
        return value < 1 && text.hasPrefix("0") ? String(text.dropFirst()) : text
    }

    /// The marks on the wheel: every 0.1 up to 2, every 0.5 up to 5, then whole numbers, and each stop.
    static func ticks(in range: ClosedRange<Double>, stops: [Double]) -> [Double] {
        var marks = stops
        var value = (range.lowerBound * 10).rounded(.up) / 10
        while value <= range.upperBound + 0.001 {
            marks.append(value)
            value = ((value + (value < 2 ? 0.1 : value < 5 ? 0.5 : 1)) * 1000).rounded() / 1000
        }
        var seen = Set<Int>()
        return marks.filter { range.contains($0) && seen.insert(Int(($0 * 100).rounded())).inserted }.sorted()
    }
}

/// A single button with the zoom now; a tap opens it into the lens buttons in a capsule, as in the Camera app, which fold back
/// after a moment. Holding or dragging along it opens a wheel that sets the zoom continuously and closes a moment after the
/// finger lifts.
struct ZoomControl: View {
    @ObservedObject var camera: CameraModel
    @State private var expanded = false
    @State private var folding: Task<Void, Never>?
    @State private var wheelOpen = false
    @State private var startZoom: Double?
    @State private var dragOrigin: CGFloat?
    @GestureState private var pressed = false
    @State private var hold: Task<Void, Never>?
    @State private var closing: Task<Void, Never>?
    @State private var haptic = UISelectionFeedbackGenerator()

    private var values: [Double] { camera.stops.map(\.value) }
    private var range: ClosedRange<Double> { ZoomDial.range(stops: values, top: camera.zoomCeiling) }

    var body: some View {
        ZStack {
            capsule.opacity(wheelOpen ? 0 : 1)
            wheel.opacity(wheelOpen ? 1 : 0)
        }
        .frame(height: 52)
        .animation(.easeOut(duration: 0.15), value: wheelOpen)
        .simultaneousGesture(touch)
        .onChange(of: pressed) { _, down in if !down { released() } }
        .onChange(of: camera.otherTouches) { _, _ in fold() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom")
        .accessibilityValue(ZoomDial.label(camera.zoomLevel, active: true))
        .accessibilityIdentifier("camera.zoom")
        .accessibilityAction { expand() }
        .accessibilityAdjustableAction { direction in
            guard let next = ZoomDial.step(from: camera.zoomLevel, stops: values, up: direction == .increment) else { return }
            camera.animateZoom(to: next)
        }
    }

    private var current: Double? { values.last { $0 <= camera.zoomLevel + 0.01 } }

    private var capsule: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let active = value == current
                let size: CGFloat = active ? 40 : 32
                if expanded || active {
                    Button { tapped(value) } label: {
                        Text(ZoomDial.label(active ? camera.zoomLevel : value, active: active))
                            .font(.system(size: active ? 15 : 13, weight: .semibold))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .foregroundStyle(active ? Color.yellow : Color.white)
                            .frame(width: size, height: size)
                            .background(Color.black.opacity(active ? 0.55 : 0.2), in: Circle())
                    }
                    .allowsHitTesting(!wheelOpen)
                    .accessibilityIdentifier("camera.lens." + ZoomDial.label(value, active: false))
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .animation(.easeOut(duration: 0.2), value: expanded)
        .padding(4)
        .background(Color.black.opacity(expanded ? 0.35 : 0), in: Capsule())
    }

    private var wheel: some View {
        let marks = ZoomDial.ticks(in: range, stops: values)
        let zoom = camera.zoomLevel
        return Canvas { context, size in
            let middle = size.width / 2
            for mark in marks {
                let x = middle + ZoomDial.offset(of: mark, from: zoom)
                guard x > 6, x < size.width - 6 else { continue }
                let major = values.contains { abs($0 - mark) < 0.001 }
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 8))
                line.addLine(to: CGPoint(x: x, y: size.height - (major ? 24 : 16)))
                context.stroke(line, with: .color(.white.opacity(major ? 0.9 : 0.5)), lineWidth: major ? 1.5 : 1)
                if major {
                    context.draw(Text(ZoomDial.label(mark, active: false)).font(.caption2.weight(.semibold)).foregroundStyle(.white),
                                 at: CGPoint(x: x, y: 12))
                }
            }
            var pointer = Path()
            pointer.move(to: CGPoint(x: middle, y: size.height - 28))
            pointer.addLine(to: CGPoint(x: middle, y: size.height - 6))
            context.stroke(pointer, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 260, height: 52)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(alignment: .top) {
            Text(ZoomDial.label(camera.zoomLevel, active: true))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
                .offset(y: -26)
        }
        .allowsHitTesting(wheelOpen)
    }

    private func tapped(_ value: Double) {
        guard !wheelOpen else { return }
        guard expanded else {
            expand()
            return
        }
        scheduleFold()
        guard abs(camera.zoomLevel - value) > 0.01 else { return }
        camera.animateZoom(to: value)
    }

    private func expand() {
        expanded = true
        scheduleFold()
    }

    private func fold() {
        folding?.cancel()
        expanded = false
    }

    private func scheduleFold() {
        folding?.cancel()
        folding = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            expanded = false
        }
    }

    // Touch down starts a hold that opens the wheel; moving along the control opens it at once.
    private var touch: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if startZoom == nil {
                    startZoom = camera.zoomLevel
                    closing?.cancel()
                    folding?.cancel()
                    hold = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        wheelOpen = true
                    }
                }
                if dragOrigin == nil, abs(drag.translation.width) > 6 {
                    dragOrigin = drag.translation.width
                    wheelOpen = true
                }
                guard wheelOpen, let start = startZoom else { return }
                let zoom = ZoomDial.zoom(from: start, dragged: drag.translation.width - (dragOrigin ?? 0), in: range)
                if ZoomDial.crossesStop(from: camera.zoomLevel, to: zoom, stops: values) { haptic.selectionChanged() }
                camera.setZoom(zoom)
            }
            .updating($pressed) { _, state, _ in state = true }
    }

    // Runs when the finger lifts and also when the system takes the touch away, which a gesture's own end does not.
    private func released() {
        hold?.cancel()
        startZoom = nil
        dragOrigin = nil
        guard wheelOpen else {
            if expanded { scheduleFold() }
            return
        }
        closing = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            wheelOpen = false
            expanded = false
        }
    }
}
#endif
