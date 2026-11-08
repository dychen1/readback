import ReadBackCore
import SwiftUI

/// PLACEHOLDER History window. Replace it when the user chooses a visual direction.
/// Keep the behavior in `HistoryListModel` so that the final design can use it without changes.
struct HistoryPlaceholderView: View {
    @ObservedObject var model: HistoryListModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let actionError = model.actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Clear History…", role: .destructive) {
                    model.requestClear()
                }
                .disabled(model.entries.isEmpty)
            }
            .padding(10)
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: Binding(
                get: { model.isConfirmingClear },
                set: { if !$0 { model.cancelClear() } }
            )
        ) {
            Button("Clear History", role: .destructive) {
                Task { await model.clear() }
            }
        } message: {
            Text("This deletes every saved read-back. You cannot undo this.")
        }
        .task {
            await model.observeChanges()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .unavailable(let message):
            ContentUnavailableView(
                "History unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let entries) where entries.isEmpty:
            ContentUnavailableView(
                "No read-backs yet",
                systemImage: "clock",
                description: Text("Text you hear appears here, newest first.")
            )
        case .loaded(let entries):
            List(entries) { entry in
                row(entry)
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.firstLine)
                    .lineLimit(1)
                Text(
                    "\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.source.displayName)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.play(entry)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly)
            .help("Play")
            Button(role: .destructive) {
                Task { await model.delete(entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}
