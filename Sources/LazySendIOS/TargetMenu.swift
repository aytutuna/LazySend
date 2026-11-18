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
#endif
