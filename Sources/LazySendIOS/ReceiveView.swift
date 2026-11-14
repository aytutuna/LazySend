#if os(iOS)
import LazySendKit
import SwiftUI
import UIKit

struct ReceiveView: View {
    @ObservedObject var host: HostModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Receive from a phone").font(.title2.bold())
                Text("On the other phone, open Lazy Send, choose Pair a PC and scan this code. Both phones need to be on the same network. "
                    + "Nothing goes through the internet.")
                    .foregroundStyle(.secondary)
                content
                Text("Keep Lazy Send open to receive. This phone stops listening when you leave the app and starts again when you come back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("receive.foreground")
            }
            .padding()
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { host.beginReceiving() }
        .onDisappear { host.endReceiving() }
        .alert(approvalTitle, isPresented: Binding(get: { host.approval != nil }, set: { if !$0 { host.answerApproval(false) } }),
               presenting: host.approval) { _ in
            Button("Don't allow", role: .cancel) { host.answerApproval(false) }
            Button("Allow") { host.answerApproval(true) }
        } message: { approval in
            Text(approvalMessage(approval))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let problem = host.problem {
            Text(problem).foregroundStyle(.red).accessibilityIdentifier("receive.problem")
        } else if let pairing = host.pairing {
            code(pairing)
        } else {
            ProgressView()
        }
    }

    private func code(_ pairing: HostPairing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = QRCode.image(for: pairing.link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Pairing code to scan")
            }
            status(pairing)
            Text("Code to type on a computer").font(.caption).foregroundStyle(.secondary)
            Text(pairing.shortCode)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("receive.shortCode")
            Text("The computer then shows").font(.caption).foregroundStyle(.secondary)
            Text(pairing.match)
                .font(.system(size: 20, design: .monospaced))
                .accessibilityIdentifier("receive.match")
            Text("Check code for a phone").font(.caption).foregroundStyle(.secondary)
            Text(pairing.check)
                .font(.system(size: 20, design: .monospaced))
                .accessibilityIdentifier("receive.check")
            HStack {
                Button("Copy link") { UIPasteboard.general.string = pairing.link }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("receive.copy")
                ShareLink(item: pairing.link) { Text("Share link") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("receive.share")
            }
        }
    }

    @ViewBuilder
    private func status(_ pairing: HostPairing) -> some View {
        if let name = pairing.pairedName {
            Text("Paired with \(name).").fontWeight(.semibold)
        } else if pairing.finished {
            Text(host.approval == nil ? "This code has expired or was used." : "A phone is waiting for your answer.").fontWeight(.semibold)
            Button("New code") { host.renewPairing() }
                .buttonStyle(.borderedProminent)
        } else {
            HStack(spacing: 4) {
                Text("Scan within")
                Text(pairing.expires, style: .timer)
            }
            .fontWeight(.semibold)
        }
        if pairing.pairedName != nil {
            Button("New code") { host.renewPairing() }
                .buttonStyle(.bordered)
        }
    }

    private var approvalTitle: String {
        host.approval.map { String(localized: "Pair with \"\($0.name)\"?") } ?? ""
    }

    private func approvalMessage(_ approval: HostApproval) -> String {
        let kind = approval.platform.isEmpty ? "" : " (\(approval.platform))"
        let name = "\"\(approval.name)\"\(kind)"
        if approval.match.isEmpty {
            return String(localized: "\(name) wants to pair with this phone. Allow it only if you just started it yourself.")
        }
        return String(localized: "\(name) wants to pair with this phone. Allow it only if you just started it yourself and it shows \(approval.match) too.")
    }
}
#endif
