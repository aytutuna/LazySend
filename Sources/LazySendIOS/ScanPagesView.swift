#if os(iOS)
import LazySendKit
import LazySendScan
import SwiftUI
import UIKit

/// The pages taken so far, in the order they will go: look at one, cut it again, move it earlier or later, delete it. Done sends
/// them to the chosen device, one page as the image it is and more as one PDF.
struct ScanPagesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scan: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: ScanPage?
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(scan.pages.enumerated()), id: \.element.id) { index, page in
                    row(index, page)
                }
                .onDelete { offsets in
                    let ids = offsets.map { scan.pages[$0].id }
                    ids.forEach { scan.delete($0) }
                }
                if let who = model.selectedTarget?.name, !scan.pages.isEmpty {
                    Group {
                        if scan.pages.count == 1 {
                            Text("Done sends the page to \(who) as an image.")
                        } else {
                            Text("Done sends the pages to \(who) as one PDF.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("pages.footer")
                }
            }
            .overlay {
                if scan.pages.isEmpty {
                    Text("No pages yet")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pages.empty")
                }
            }
            .navigationTitle(ScanText.pages(scan.pages.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep scanning") { dismiss() }
                        .accessibilityIdentifier("pages.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                        .disabled(scan.pages.isEmpty || model.selectedTarget == nil || sending || scan.working)
                        .accessibilityIdentifier("pages.done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("pages.failure")
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .fullScreenCover(item: $viewing) { page in
            PageViewer(page: page)
        }
        .fullScreenCover(item: $scan.pageEditing) { request in
            CornerEditorView(request: request) { scan.answer(request, $0) }
        }
        .onChange(of: scan.pages.isEmpty) { _, empty in
            if empty && !sending { dismiss() }
        }
    }

    private func row(_ index: Int, _ page: ScanPage) -> some View {
        HStack(spacing: 12) {
            Button { viewing = page } label: {
                HStack(spacing: 12) {
                    Group {
                        if let image = scan.thumbnail(page) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .frame(width: 48, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(index + 1)")
                        Text(ScanText.name(page.filter))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("page.\(index)")
            Menu {
                Button("View", systemImage: "eye") { viewing = page }
                Button("Crop", systemImage: "crop") { scan.recut(page) }
                    .disabled(scan.working)
                Button("Move earlier", systemImage: "arrow.up") { scan.shift(page.id, by: -1) }
                    .disabled(index == 0)
                Button("Move later", systemImage: "arrow.down") { scan.shift(page.id, by: 1) }
                    .disabled(index == scan.pages.count - 1)
                Button("Delete", systemImage: "trash", role: .destructive) { scan.delete(page.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Page \(index + 1) options")
            .accessibilityIdentifier("page.\(index).menu")
        }
    }

    private func done() {
        guard let target = model.selectedTarget else { return }
        sending = true
        failure = nil
        Task {
            do {
                let name = try await model.sendScan(scan.pages, to: target)
                scan.sent(name)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

/// One page, large, to pinch and pan.
struct PageViewer: View {
    let page: ScanPage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var zoomAtStart: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image = UIImage(data: page.jpeg) {
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width * zoom, height: proxy.size.height * zoom)
                            .accessibilityIdentifier("viewer.page")
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom = min(max(zoomAtStart * $0.magnification, 1), 5) }
                        .onEnded { _ in zoomAtStart = zoom })
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
            .accessibilityIdentifier("viewer.close")
        }
    }
}
#endif
