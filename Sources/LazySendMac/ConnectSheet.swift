#if os(macOS)
import AppKit
import SwiftUI

struct ConnectSheet: View {
    @ObservedObject var model: ConnectModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a computer").font(.title2.weight(.semibold))
            Text("On the other computer, open Lazy Send and choose Pair a phone. It shows a code and a link. "
                + "Nothing goes through the internet: the two computers talk directly, encrypted.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Computers nearby").font(.headline)
                Spacer()
                Button {
                    Task { await model.look() }
                } label: {
                    Label("Look again", systemImage: "arrow.clockwise")
                }
                .disabled(model.looking || model.busy)
            }
            nearbyList
            Text("Code or link").font(.headline).padding(.top, 4)
            Text("Choose the computer above and type the code it shows, like 7KQ2-M9XD. Or paste its link (lazysend://pair?...) and no choice is needed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code or link", text: $model.input)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                .onSubmit { model.connect() }
            if let digits = digitsShown {
                digitsCard(digits)
            }
            if !model.message.isEmpty {
                Text(model.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if case .connected(let name) = model.step {
                    Text("Connected to \(name).").font(.caption)
                }
                Spacer()
                if case .connected = model.step {
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Connect") { model.connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 560)
        .task { await model.look() }
    }

    private var nearbyList: some View {
        Group {
            if model.nearby.isEmpty {
                Text(model.looking ? "Looking for computers..." : "No computer found. Both need to be on the same network, with Lazy Send open. You can still paste a link below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.nearby) { host in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(host.name).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(host.id == model.selected ? Color.accentColor.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { if !model.busy { model.selected = host.id } }
                        .accessibilityLabel(host.name)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private var digitsShown: String? {
        switch model.step {
        case .comparing(let digits): return digits
        case .waiting(let digits): return digits
        default: return nil
        }
    }

    private func digitsCard(_ digits: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(digits).font(.system(size: 22, design: .monospaced)).textSelection(.enabled)
            if case .comparing = model.step {
                Text("Does the other computer show these same digits under its code? If not, choose No: another computer may be answering, and nothing is sent to it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Yes, they match") { model.answer(matches: true) }
                        .buttonStyle(.borderedProminent)
                    Button("No") { model.answer(matches: false) }
                }
            } else {
                Text("Waiting for the other computer. Its screen should show these same digits. Choose Allow there only if they match.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
    }
}
#endif
