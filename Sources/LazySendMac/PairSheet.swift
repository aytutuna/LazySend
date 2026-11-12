#if os(macOS)
import AppKit
import SwiftUI

struct PairSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a phone").font(.title2.weight(.semibold))
            Text("Open Lazy Send on your phone, choose Pair with a computer and scan this code. The code works once, for 5 minutes. "
                + "Nothing goes through the internet: the phone and this Mac talk directly, encrypted.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let approval = model.approval {
                approvalCard(approval)
            }
            if let state = model.pairing {
                codeCard(state)
                Text("Cannot scan the code?").font(.headline).padding(.top, 4)
                Text("Get this pairing text onto the phone (a message to yourself, say) and paste it in Lazy Send there, then compare the check code.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.code.uri)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .accessibilityLabel("Pairing text")
                Button {
                    model.copy(state.code.uri)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityLabel("Copy the pairing text")
            }
            if !model.status.isEmpty {
                Text("Connection").font(.headline).padding(.top, 4)
                Text(model.status).foregroundStyle(.secondary)
            }
            HStack {
                if let name = model.pairing?.pairedName {
                    Text("Paired with \(name).").font(.caption)
                }
                Spacer()
                Button("Close") { model.closePairing() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 640)
    }

    private func approvalCard(_ approval: PairApproval) -> some View {
        let kind = approval.platform.isEmpty ? "" : " (\(approval.platform))"
        return VStack(alignment: .leading, spacing: 8) {
            Text("\"\(approval.name)\"\(kind) wants to pair with this Mac. Allow it only if you just scanned the code yourself.")
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow") { model.answerApproval(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                Button("Don't allow") { model.answerApproval(false) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
    }

    private func codeCard(_ state: PairingState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let image = QRCode.image(for: state.code.uri) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                } else {
                    Color.white.frame(width: 200, height: 200)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Pairing code to scan with your phone")
            VStack(alignment: .leading, spacing: 4) {
                Text(expiry(state)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                if state.finished && state.pairedName == nil {
                    Button("New code") { Task { await model.renewPairing() } }
                }
                Text("Check code").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Text(state.code.checkCode).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                Text("This Mac is reachable at").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                Text(state.code.addresses.isEmpty ? "No network address found" : state.code.addresses.joined(separator: "  "))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private func expiry(_ state: PairingState) -> String {
        if let name = state.pairedName { return "Paired with \(name)." }
        if state.remaining <= 0 { return model.approval != nil ? "A phone is waiting for your answer." : "This code has expired or was used." }
        return "Scan within \(state.remaining / 60):" + String(format: "%02d", state.remaining % 60)
    }
}
#endif
