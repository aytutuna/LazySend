#if os(macOS)
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var login = LoginItem.isEnabled

    var body: some View {
        Form {
            LabeledContent("Receive folder") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(model.receiveFolder).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    HStack {
                        Button("Choose...") { choose() }
                        Button("Use the default") { model.useDefaultReceiveFolder() }
                            .disabled(model.service.settings.isDefaultReceiveRoot)
                    }
                }
            }
            Toggle("Copy received text to the clipboard", isOn: $model.copyReceivedText)
            Toggle("Open Lazy Send at login", isOn: Binding(get: { login }, set: { login = $0; LoginItem.set($0) }))
        }
        .padding(20)
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.chooseReceiveFolder(url) }
    }
}
#endif
