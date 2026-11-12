import LazySendKit
import SwiftUI

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }

    private var title: String {
        model.state == .notPaired ? "Lazy Send" : String(localized: "Send to \(model.chosenName)")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .ready:
            if model.pcs.count > 1 {
                Picker("PC", selection: $model.chosen) {
                    ForEach(model.pcs) { pc in
                        Text(pc.name).tag(pc.id)
                    }
                }
                .pickerStyle(.menu)
            }
            Text(model.summary).lineLimit(2).foregroundStyle(.secondary)
            Button("Send") { model.send() }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { model.close() }
        case .sending:
            ProgressView(value: model.progress)
            Text("Sending…").foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Sent")
        case .saved(let message):
            Text(message).multilineTextAlignment(.center)
            Button("Done") { model.done() }
                .buttonStyle(.borderedProminent)
        case .failed(let message, let retry):
            Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
            if retry {
                Button("Try again") { model.send() }
                    .buttonStyle(.borderedProminent)
                Button("Send later") { model.sendLater() }
            }
            Button("Cancel") { model.close() }
        case .notPaired:
            Text("Open Lazy Send and pair a PC first.").multilineTextAlignment(.center)
            Button("Done") { model.done() }
                .buttonStyle(.borderedProminent)
        }
    }
}
