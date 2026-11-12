#if os(iOS)
import LazySendKit
import SwiftUI
import UIKit

@MainActor
final class PairModel: ObservableObject {
    enum Step: Equatable {
        case scanning
        case waiting(checkCode: String)
        case failed(String)
        case paired(String)
    }

    @Published private(set) var step = Step.scanning
    @Published private(set) var parseError: String?
    @Published var pasted = ""

    private let app: AppModel
    private var task: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    func submit(_ text: String) {
        guard task == nil, step == .scanning else { return }
        let code: PairingCode
        do {
            code = try PairingCode.parse(text)
        } catch {
            parseError = error.localizedDescription
            return
        }
        parseError = nil
        step = .waiting(checkCode: code.checkCode)
        task = Task {
            do {
                let pc = try await self.app.pair(code)
                self.step = .paired(pc.name)
            } catch {
                self.step = .failed(error.localizedDescription)
            }
            self.task = nil
        }
    }

    func retry() {
        step = .scanning
    }

    func finished() async {
        await task?.value
    }
}

struct PairView: View {
    @StateObject private var pair: PairModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel) {
        _pair = StateObject(wrappedValue: PairModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding()
        }
        .navigationTitle("Pair with your PC")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pair.step) { _, step in
            if case .paired = step { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pair.step {
        case .scanning:
            scanning
        case .waiting(let code):
            Text("Approve on your PC").font(.title2.bold())
            Text("Check that the code on your PC says the same, then approve this phone there.")
            Text("Check code").font(.subheadline).foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundStyle(.tint)
                .accessibilityIdentifier("pair.checkCode")
            ProgressView()
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Try again") { pair.retry() }
                .buttonStyle(.borderedProminent)
        case .paired(let name):
            Text("Paired with \(name)").font(.title2.bold())
        }
    }

    @ViewBuilder
    private var scanning: some View {
        PairingScannerView { pair.submit($0) }
        Text("Point the camera at the code on your PC.").foregroundStyle(.secondary)
        Text("Paste pairing text").font(.subheadline)
        TextField("lazysend://pair?…", text: $pair.pasted, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("pair.paste")
        if let error = pair.parseError {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("pair.error")
        }
        HStack {
            Button("Paste") {
                if let text = UIPasteboard.general.string { pair.pasted = text }
            }
            .buttonStyle(.bordered)
            Button("Connect") { pair.submit(pair.pasted) }
                .buttonStyle(.borderedProminent)
                .disabled(pair.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("pair.connect")
        }
    }
}
#endif
