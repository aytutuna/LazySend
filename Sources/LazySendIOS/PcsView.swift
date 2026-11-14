#if os(iOS)
import LazySendKit
import LazySendServer
import SwiftUI

struct PcsView: View {
    @EnvironmentObject private var model: AppModel
    let go: (Route) -> Void
    @State private var removing: PairedPc?
    @State private var removingPhone: PairedDevice?

    var body: some View {
        List {
            Section {
                if model.targets.isEmpty {
                    Text("Nothing is paired.").foregroundStyle(.secondary)
                }
                ForEach(model.pcs) { pc in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pc.name)
                            if let link = model.links[pc.id] {
                                Text("Connected over \(link.label)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Not reachable").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { removing = pc }
                            .buttonStyle(.borderless)
                    }
                }
                ForEach(model.phones) { phone in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phone.name)
                            Text("Phone that connects to this one").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { removingPhone = phone }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("devices.removePhone")
                    }
                }
                Button("Pair a PC") { go(.pair) }
                Button("Receive from a phone") { go(.receive) }
            }
            Section {
                Toggle("Save received photos and videos to Photos", isOn: Binding(
                    get: { model.savesToPhotos },
                    set: { model.setSavesToPhotos($0) }))
                    .accessibilityIdentifier("pcs.savePhotos")
            }
        }
        .navigationTitle("Paired devices")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(removing.map { String(localized: "Remove \($0.name)?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { pc in
            Button("Remove", role: .destructive) {
                Task { @MainActor in await model.remove(pc) }
            }
        } message: { _ in
            Text("This phone is forgotten on the PC as well when it can be reached.")
        }
        .confirmationDialog(removingPhone.map { String(localized: "Remove \($0.name)?") } ?? "",
                            isPresented: Binding(get: { removingPhone != nil }, set: { if !$0 { removingPhone = nil } }),
                            titleVisibility: .visible, presenting: removingPhone) { phone in
            Button("Remove", role: .destructive) { model.remove(phone: phone) }
        } message: { _ in
            Text("What is waiting for it is dropped, and it has to pair again to connect.")
        }
    }
}
#endif
