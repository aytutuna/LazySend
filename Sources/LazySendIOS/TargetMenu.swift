#if os(iOS)
import LazySendKit
import SwiftUI

/// The menu that picks the device what is sent goes to, shared by the Camera and Files tabs; it is nothing while no device is paired.
struct TargetMenu<Label: View>: View {
    @EnvironmentObject private var model: AppModel
    @ViewBuilder let label: (AppModel.Target) -> Label

    var body: some View {
        if let target = model.selectedTarget {
            Menu {
                Picker("Send to", selection: Binding(get: { target.id }, set: { model.select($0) })) {
                    ForEach(model.targets) { Text($0.name).tag($0.id) }
                }
            } label: {
                label(target)
            }
        }
    }
}

/// Green while the app holds a link to the computer, red when it does not. A phone that connects to this one has no link to show.
struct ConnectionDot: View {
    @EnvironmentObject private var model: AppModel
    let target: AppModel.Target

    var body: some View {
        if !target.phone {
            let connected = model.links[target.id] != nil
            Circle()
                .fill(connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(connected ? Text("Connected") : Text("Not connected"))
                .accessibilityIdentifier("camera.connection")
        }
    }
}
#endif
