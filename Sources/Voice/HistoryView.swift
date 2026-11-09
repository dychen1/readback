import ReadBackCore
import SwiftUI

/// The History window: a list of read-backs grouped by day, and a reader for the selected entry.
struct HistoryView: View {
    @ObservedObject var model: HistoryListModel
    let voiceName: String
    @FocusState private var isListFocused: Bool
    private let labels = HistoryDateLabels()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 232, max: 320)
        } detail: {
            detail
                .navigationTitle("History")
                .navigationSubtitle(model.selectedEntry.map(labels.subtitle) ?? "")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        playStopButton
                        deleteButton
                    }
                }
        }
        .toolbar(removing: .sidebarToggle)
        .defaultFocus($isListFocused, true)
        .onExitCommand { model.stopPlayback() }
        .confirmationDialog(
            model.clearConfirmationTitle,
            isPresented: Binding(
                get: { model.isConfirmingClear },
                set: { if !$0 { model.cancelClear() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    await model.clear()
                    isListFocused = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You cannot undo this.")
        }
        .task { await model.observeChanges() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedEntryID) {
            ForEach(labels.groups(model.entries, now: Date())) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            labels: labels,
                            indicator: model.rowIndicator(for: entry),
                            isSelected: entry.id == model.selectedEntryID
                        )
                        .tag(entry.id)
                        .accessibilityAction(named: "Play") { model.play(entry) }
                        .accessibilityAction(named: "Delete") { Task { await model.delete(entry) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let entry = entry(in: ids) {
                Button("Play") { model.play(entry) }
                Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
            }
        } primaryAction: { ids in
            if let entry = entry(in: ids) { model.play(entry) }
        }
        .onKeyPress(.space) {
            model.togglePlaySelected()
            return .handled
        }
        .onKeyPress(.return) {
            model.playSelected()
            return .handled
        }
        .onDeleteCommand { Task { await model.deleteSelected() } }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let actionError = model.actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
            }
            Button("Clear History…") { model.requestClear() }
                .buttonStyle(.borderless)
                .disabled(model.entries.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private func entry(in ids: Set<HistoryEntry.ID>) -> HistoryEntry? {
        guard let id = ids.first else { return nil }
        return model.entries.first { $0.id == id }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch model.state {
        case .loading:
            Color.clear
        case .unavailable(let message):
            ContentUnavailableView(
                "History unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let entries) where entries.isEmpty:
            ContentUnavailableView {
                Label("No read-backs yet", systemImage: "waveform.circle")
            } description: {
                Text("Read-backs from agents, Read Clipboard (⌥⌘R) and voicepipe will appear here, so you can hear them again.")
            }
        case .loaded:
            if let entry = model.selectedEntry {
                HistoryReaderView(entry: entry, spokenRange: model.spokenRange(in: entry))
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let progress = model.progress(in: entry) {
                            HistoryProgressLine(value: progress)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HistoryHintBar(voiceName: voiceName, error: model.playbackError)
                    }
            } else {
                ContentUnavailableView("Select a read-back", systemImage: "text.alignleft")
            }
        }
    }

    private var playStopButton: some View {
        let isPlaying = model.isSelectionPlaying
        return Button {
            model.togglePlaySelected()
        } label: {
            Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                .frame(minWidth: 52)
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.titleAndIcon)
        .help(isPlaying ? "Stop (Space or esc)" : "Play (Space or Return)")
        .disabled(model.selectedEntry == nil)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await model.deleteSelected() }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .help("Delete (⌫)")
        .disabled(model.selectedEntry == nil)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let labels: HistoryDateLabels
    let indicator: HistoryRowIndicator
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: entry.source.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.firstSentence)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    indicatorMark
                }
                HStack(spacing: 4) {
                    Text(entry.source.displayName)
                    Spacer(minLength: 4)
                    Text(labels.time(entry.createdAt))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.accessibilityLabel(for: entry, indicator: indicator))
    }

    @ViewBuilder
    private var indicatorMark: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .playing:
            Image(systemName: "waveform")
                .foregroundStyle(markStyle)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .paused:
            Image(systemName: "pause.fill")
                .foregroundStyle(markStyle)
        }
    }

    /// The accent color is not visible on the accent-colored selection.
    private var markStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }
}
