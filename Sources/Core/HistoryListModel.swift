import Combine
import Foundation

/// Holds the behavior of the History window. The views contain no logic, so a new design can
/// use this model without changes.
@MainActor
public final class HistoryListModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case loaded([HistoryEntry])
        case unavailable(String)
    }

    @Published public private(set) var state: State = .loading
    @Published public var selectedEntryID: HistoryEntry.ID?
    /// The History entry that plays now. The app sets it with `playbackDidChange(_:)`.
    @Published public private(set) var playback: HistoryPlayback?
    /// Tells why the last replay failed. The next replay sets it to `nil`.
    @Published public private(set) var playbackError: String?
    /// Tells why the last delete or clear failed. The next successful delete or clear sets it
    /// to `nil`.
    @Published public private(set) var actionError: String?
    @Published public private(set) var isConfirmingClear = false

    /// A token stream changes its entry many times a second. Four reloads a second keep the
    /// list current without a reload for each token.
    public static let minimumRefreshInterval: Duration = .milliseconds(250)

    private let store: HistoryStore
    private let replay: @MainActor (HistoryEntry) -> Void
    private let stop: @MainActor () -> Void
    private var selectsFirstEntryOnLoad = true

    /// - Parameters:
    ///   - replay: Stops the current reading and plays the entry.
    ///   - stop: Stops the current reading, whatever started it.
    public init(
        store: HistoryStore,
        replay: @escaping @MainActor (HistoryEntry) -> Void,
        stop: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.replay = replay
        self.stop = stop
    }

    /// The entries, newest first. The list is empty while history loads or is unavailable.
    public var entries: [HistoryEntry] {
        if case .loaded(let entries) = state { entries } else { [] }
    }

    public var selectedEntry: HistoryEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    /// True while the entry starts, plays or pauses. The Play button then reads "Stop".
    public func isPlaying(_ entry: HistoryEntry) -> Bool {
        playback?.entryID == entry.id
    }

    public var isSelectionPlaying: Bool {
        selectedEntry.map(isPlaying) ?? false
    }

    /// The part of `entry` that plays now, as character offsets into its text. It is `nil`
    /// when `entry` does not play or no chunk of it plays yet.
    public func spokenRange(in entry: HistoryEntry) -> Range<Int>? {
        guard let playback, playback.entryID == entry.id, let range = playback.spokenRange else {
            return nil
        }
        return entry.characterRange(forScalarRange: range)
    }

    /// How much of `entry` played, from 0 to 1, or `nil` when `entry` does not play or no
    /// chunk of it plays yet.
    public func progress(in entry: HistoryEntry) -> Double? {
        guard let playback, playback.entryID == entry.id else { return nil }
        return playback.progress(textLength: entry.text.unicodeScalars.count)
    }

    public func rowIndicator(for entry: HistoryEntry) -> HistoryRowIndicator {
        HistoryRowIndicator(playback: playback, entryID: entry.id)
    }

    /// For example "Clear all 12 read-backs?".
    public var clearConfirmationTitle: String {
        entries.count == 1 ? "Clear 1 read-back?" : "Clear all \(entries.count) read-backs?"
    }

    public func refresh() async {
        do {
            let entries = try await store.entries()
            state = .loaded(entries)
            keepSelectionValid(in: entries)
        } catch {
            state = .unavailable(error.localizedDescription)
            selectedEntryID = nil
        }
    }

    /// Loads the list again after changes, at most once per `minimumRefreshInterval`. Changes
    /// in that time become one reload. It stops when the caller cancels its task, for example
    /// a view's `.task`. If nothing is selected, the first load selects the newest entry.
    public func observeChanges() async {
        let changes = await store.changes()
        selectsFirstEntryOnLoad = true
        await refresh()
        for await _ in changes {
            await refresh()
            try? await Task.sleep(for: Self.minimumRefreshInterval)
        }
    }

    // MARK: - Playback

    public func play(_ entry: HistoryEntry) {
        playbackError = nil
        replay(entry)
    }

    /// Plays the selected entry from the start. If the entry plays now, it starts again.
    public func playSelected() {
        if let selectedEntry { play(selectedEntry) }
    }

    /// Stops the selected entry if it plays now. Otherwise plays it.
    public func togglePlaySelected() {
        guard let selectedEntry else { return }
        if isPlaying(selectedEntry) {
            stopPlayback()
        } else {
            play(selectedEntry)
        }
    }

    public func stopPlayback() {
        stop()
    }

    public func playbackDidChange(_ playback: HistoryPlayback?) {
        self.playback = playback
    }

    public func replayDidFail(_ message: String) {
        playbackError = message
    }

    // MARK: - Delete and clear

    /// Deletes the entry. If the entry plays now, playback stops first. If the entry was
    /// selected, the model selects the next older entry, or the newer one if no older entry exists.
    public func delete(_ entry: HistoryEntry) async {
        if isPlaying(entry) { stopPlayback() }
        let wasSelected = selectedEntryID == entry.id
        let nextSelection = wasSelected ? entryID(after: entry.id) : selectedEntryID
        await perform("ReadBack did not delete the entry.") { try await $0.delete(id: entry.id) }
        if wasSelected, actionError == nil {
            selectedEntryID = nextSelection
        }
    }

    public func deleteSelected() async {
        if let selectedEntry { await delete(selectedEntry) }
    }

    /// Asks for confirmation before `clear()`. An empty list has nothing to confirm.
    public func requestClear() {
        isConfirmingClear = !entries.isEmpty
    }

    public func cancelClear() {
        isConfirmingClear = false
    }

    /// Stops playback, deletes all entries and selects nothing.
    public func clear() async {
        isConfirmingClear = false
        if playback != nil { stopPlayback() }
        await perform("ReadBack did not clear history.") { try await $0.clear() }
        if actionError == nil {
            selectedEntryID = nil
        }
    }

    private func perform(
        _ failureMessage: String,
        _ change: (HistoryStore) async throws -> Void
    ) async {
        do {
            try await change(store)
            actionError = nil
        } catch {
            actionError = "\(failureMessage) \(error.localizedDescription)"
        }
        await refresh()
    }

    private func entryID(after id: HistoryEntry.ID) -> HistoryEntry.ID? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if entries.indices.contains(index + 1) { return entries[index + 1].id }
        return index > 0 ? entries[index - 1].id : nil
    }

    private func keepSelectionValid(in entries: [HistoryEntry]) {
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = entries.first?.id
        }
        if selectedEntryID == nil, selectsFirstEntryOnLoad, let newest = entries.first {
            selectedEntryID = newest.id
        }
        if !entries.isEmpty {
            selectsFirstEntryOnLoad = false
        }
    }
}

extension HistoryEntry {
    /// The first line that is not blank, without the spaces at each end.
    public var firstLine: String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

extension HistorySource {
    /// The agent host name when it is known, for example "Cursor". A host name that equals
    /// the name of another source, such as "Clipboard", shows as "Agent · Clipboard", so an
    /// agent cannot pass as that source.
    public var displayName: String {
        switch self {
        case .agent(let host?):
            Self.builtInNames.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
                ? "\(Self.agentName) · \(host)"
                : host
        case .agent(nil): Self.agentName
        case .clipboard: "Clipboard"
        case .voicepipe: "voicepipe"
        }
    }

    private static let agentName = "Agent"
    private static let builtInNames = [agentName, clipboard.displayName, voicepipe.displayName]
}
