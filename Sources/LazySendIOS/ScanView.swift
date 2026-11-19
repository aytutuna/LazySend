#if os(iOS)
import LazySendKit
import LazySendScan
import SwiftUI

/// What the camera tab does: takes photos to send, or scans pages into one file.
enum CameraMode: Hashable {
    case photo
    case scan
}

/// The switch at the top of the camera tab. The segment of the mode in use is filled.
struct ModeSwitch: View {
    @Binding var mode: CameraMode

    var body: some View {
        HStack(spacing: 0) {
            segment("Photo", .photo, "mode.photo")
            segment("Scan", .scan, "mode.scan")
        }
        .background(Capsule().fill(Color.black.opacity(0.4)))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func segment(_ title: LocalizedStringKey, _ value: CameraMode, _ identifier: String) -> some View {
        Button { mode = value } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Capsule().fill(mode == value ? Color.accentColor : Color.clear))
        }
        .accessibilityAddTraits(mode == value ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

enum ScanText {
    static func pages(_ count: Int) -> String {
        count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
    }

    static func name(_ filter: CaptureFilter) -> String {
        switch filter {
        case .enhanced: return String(localized: "Enhanced")
        case .original: return String(localized: "Original")
        case .grayscale: return String(localized: "Grayscale")
        case .blackAndWhite: return String(localized: "B&W")
        case .whiteboard: return String(localized: "Whiteboard")
        }
    }
}

/// The camera tab in scan mode, over the live picture: the Auto chip and the light, the line that says what the page in view is
/// waiting for, the Controls pill with its drawer, and the bottom row with the pages taken, the shutter and room for nothing else.
struct ScanChrome: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraModel
    @ObservedObject var scan: ScanModel
    @ObservedObject var timeline: Timeline
    @Binding var mode: CameraMode
    @Binding var drawerOpen: Bool
    @Binding var showsPages: Bool
    let wide: Bool
    let pair: () -> Void
    @State private var sentHidden = false
    @State private var group = DrawerGroup.filter

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let controls = wide ? AnyLayout(VStackLayout(spacing: 24)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 12) {
                topBar
                if model.targets.isEmpty { PairCard(pair: pair) }
                if let problem = scan.problem {
                    Text(problem).font(.footnote).foregroundStyle(.white).padding(8).background(Color.red.opacity(0.8), in: Capsule())
                        .accessibilityIdentifier("scan.problem")
                }
                if let line = statusLine {
                    StatusPill(text: line.text, identifier: line.id)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            if !wide { Spacer(minLength: 0) }
            VStack(spacing: 0) {
                DrawerHandle(open: $drawerOpen)
                if drawerOpen {
                    ScanDrawer(camera: camera, group: $group)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                controls {
                    pagesStack
                    if !wide { Spacer() }
                    shutter
                    if !wide { Spacer() }
                    // The stack's width again, so the shutter stays in the middle.
                    Color.clear.frame(width: 70, height: 72)
                }
                .padding(wide ? .horizontal : .vertical, 20)
                .padding(.horizontal, wide ? 0 : 24)
            }
            .frame(maxHeight: wide ? .infinity : nil)
        }
        .onChange(of: scan.lastName) { _, _ in sentHidden = false }
        .onChange(of: sentEntry?.state) { _, state in
            guard state == .done else { return }
            sentHidden = false
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                sentHidden = true
            }
        }
    }

    // MARK: The top bar

    private var topBar: some View {
        HStack {
            autoChip
            if camera.hasTorch {
                Button { camera.setTorch(!camera.torch) } label: {
                    Image(systemName: camera.torch ? "bolt.fill" : "bolt.slash.fill")
                        .foregroundStyle(camera.torch ? Color.yellow : Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel(camera.torch ? Text("Light on") : Text("Light off"))
                .accessibilityIdentifier("scan.torch")
            }
            Spacer(minLength: 4)
            ModeSwitch(mode: $mode)
            TargetMenu { target in
                Label(target.name, systemImage: target.phone ? "iphone" : "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.4), in: Capsule())
            }
            .accessibilityIdentifier("camera.target")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var autoChip: some View {
        Button { model.setScanAuto(!model.scanAuto) } label: {
            Text("Auto")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Capsule().fill(model.scanAuto ? Color.accentColor : Color.black.opacity(0.4)))
        }
        .accessibilityValue(model.scanAuto ? Text("On") : Text("Off"))
        .accessibilityHint(Text("Takes each page once it holds still"))
        .accessibilityIdentifier("scan.auto")
    }

    // MARK: The line over the picture

    private var canShoot: Bool {
        scan.canShoot && model.selectedTarget != nil
    }

    private var sentEntry: TimelineEntry? {
        guard let name = scan.lastName else { return nil }
        return timeline.entries.first { $0.direction == .sent && $0.kind == .file && $0.title == name }
    }

    /// How the last scan went, until the next page is taken (and not for long once it is delivered).
    private var sentLine: (text: String, id: String)? {
        guard scan.lastName != nil, scan.pages.isEmpty, let who = sentEntry?.pcName ?? model.selectedTarget?.name else { return nil }
        switch sentEntry?.state {
        case .done: return sentHidden ? nil : (String(localized: "Sent to \(who)"), "scan.status")
        case .failed: return (String(localized: "Not sent"), "scan.status")
        default: return (String(localized: "Waiting for \(who)"), "scan.status")
        }
    }

    /// Cutting a shot out, how the last scan went, why a page held still is not taken yet or that it is about to be, how the
    /// page sits in the frame.
    private var statusLine: (text: String, id: String)? {
        if scan.working { return (String(localized: "Cutting out the page…"), "scan.working") }
        if let sent = sentLine { return sent }
        guard canShoot, let update = scan.live else { return nil }
        let followed = update.outline != nil && (update.state == .moving || update.state == .steadying)
        if followed || update.placement == .cutOff {
            switch update.placement {
            case .far: return (String(localized: "Move closer"), "scan.placement")
            case .cutOff: return (String(localized: "Fit the whole page"), "scan.placement")
            case .fine: break
            }
        }
        if model.scanAuto && update.state == .steadying {
            switch update.quality {
            case .blurry: return (update.suggestsShutter ? String(localized: "Tap the shutter") : String(localized: "Not sharp yet"), "scan.wait")
            case .dark: return (String(localized: "Too dark"), "scan.wait")
            case .good: return (String(localized: "Page found · hold still"), "scan.found")
            }
        }
        return nil
    }

    // MARK: The bottom row

    private var shutter: some View {
        let progress: CGFloat = model.scanAuto && canShoot && scan.live?.state == .steadying ? CGFloat(scan.live?.progress ?? 0) : 0
        return Button { scan.shoot() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(Color.white).frame(width: 60, height: 60)
                // Auto's count: the ring fills while the page holds still, and the page is taken when it is full.
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
                    .animation(.linear(duration: 0.1), value: progress)
            }
            .opacity(canShoot ? 1 : 0.4)
        }
        .disabled(!canShoot)
        .accessibilityLabel("Take page")
        .accessibilityIdentifier("scan.shutter")
    }

    /// The pages taken: the last on a card, a second card behind it once there are two, and the count on a badge.
    private var pagesStack: some View {
        let count = scan.pages.count
        return Button { showsPages = true } label: {
            ZStack {
                if let page = scan.pages.last, let image = scan.thumbnail(page) {
                    if count > 1 {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 46, height: 60)
                            .rotationEffect(.degrees(6))
                            .offset(x: 3, y: -2)
                    }
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white))
                        .overlay(alignment: .topTrailing) {
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(4)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 48, height: 64)
                }
            }
            .frame(width: 70, height: 72)
        }
        .disabled(count == 0)
        .accessibilityLabel(ScanText.pages(count))
        .accessibilityHint("Shows the pages taken")
        .accessibilityIdentifier("scan.pages")
    }
}

/// A group of the controls drawer.
enum DrawerGroup: String, CaseIterable, Identifiable {
    case filter
    case flash

    var id: String { rawValue }

    var symbol: String {
        self == .filter ? "circle.lefthalf.filled" : "bolt"
    }

    var title: LocalizedStringKey {
        self == .filter ? "Filter" : "Flash"
    }
}

/// The controls the pill opens, over a dark panel: the filter new pages get and, where the phone has a light, the light.
struct ScanDrawer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraModel
    @Binding var group: DrawerGroup

    var body: some View {
        let groups = camera.hasTorch ? DrawerGroup.allCases : [DrawerGroup.filter]
        let shown = groups.contains(group) ? group : DrawerGroup.filter
        return VStack(spacing: 10) {
            if groups.count > 1 {
                HStack(spacing: 14) {
                    ForEach(groups) { groupButton($0, selected: $0 == shown) }
                }
            }
            switch shown {
            case .filter: filters
            case .flash: light
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer")
    }

    private func groupButton(_ item: DrawerGroup, selected: Bool) -> some View {
        Button { group = item } label: {
            VStack(spacing: 2) {
                Image(systemName: item.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(selected ? Color.accentColor : Color.white.opacity(0.2)))
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
            }
            .frame(minWidth: 56)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("drawer." + item.rawValue)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CaptureFilter.displayOrder, id: \.self) { filter in
                    let selected = model.scanFilter == filter
                    Button { model.setScanFilter(filter) } label: {
                        Text(ScanText.name(filter))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.2)))
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("scan.filter." + filter.rawValue)
                }
            }
        }
    }

    private var light: some View {
        Picker("Flash", selection: Binding(get: { camera.torch }, set: { camera.setTorch($0) })) {
            Text("Off").tag(false)
            Text("On").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("scan.torch.picker")
    }
}

/// The Controls pill at the foot of the picture that shows or hides the drawer under it.
struct DrawerHandle: View {
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                open.toggle()
            } else {
                withAnimation(.snappy) { open.toggle() }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Controls")
                Image(systemName: open ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(Capsule().fill(open ? Color.accentColor : Color(white: 0.15)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel(open ? Text("Hide controls") : Text("Show controls"))
        .accessibilityIdentifier("drawer.toggle")
    }
}

/// A line on a dark capsule over the picture.
struct StatusPill: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .accessibilityIdentifier(identifier)
    }
}
#endif
