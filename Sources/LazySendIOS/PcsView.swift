#if os(iOS)
import LazySendKit
import SwiftUI

struct PcsView: View {
    @EnvironmentObject private var model: AppModel
    let go: (Route) -> Void
    @State private var removing: PairedPc?

    var body: some View {
        List {
            Section {
                if model.pcs.isEmpty {
                    Text("No PCs are paired.").foregroundStyle(.secondary)
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
                Button("Pair a PC") { go(.pair) }
            }
            Section {
                Toggle("Save received photos and videos to Photos", isOn: Binding(
                    get: { model.savesToPhotos },
                    set: { model.setSavesToPhotos($0) }))
                    .accessibilityIdentifier("pcs.savePhotos")
            }
        }
        .navigationTitle("Paired PCs")
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
    }
}
#endif
