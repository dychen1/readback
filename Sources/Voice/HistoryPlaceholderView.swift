import ReadBackCore
import SwiftUI

/// PLACEHOLDER History window, to be replaced once a visual direction is chosen.
/// Keep behaviour in `HistoryListModel` so the final design can reuse it unchanged.
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
            Text("This deletes every saved read-back and cannot be undone.")
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
                "History Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let entries) where entries.isEmpty:
            ContentUnavailableView(
                "No Read-Backs Yet",
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
