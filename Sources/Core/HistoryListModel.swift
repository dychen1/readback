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
    /// Tells why the last delete or clear failed. The next successful delete or clear sets it
    /// to `nil`.
    @Published public private(set) var actionError: String?
    @Published public private(set) var isConfirmingClear = false

    private let store: HistoryStore
    private let replay: @MainActor (HistoryEntry) -> Void

    public init(store: HistoryStore, replay: @escaping @MainActor (HistoryEntry) -> Void) {
        self.store = store
        self.replay = replay
    }

    /// The entries, newest first. The list is empty while history loads or is unavailable.
    public var entries: [HistoryEntry] {
        if case .loaded(let entries) = state { entries } else { [] }
    }

    public func refresh() async {
        do {
            state = .loaded(try await store.entries())
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    /// Loads the list again after each change. It stops when the caller cancels its task, for
    /// example a view's `.task`.
    public func observeChanges() async {
        let changes = await store.changes()
        await refresh()
        for await _ in changes {
            await refresh()
        }
    }

    public func play(_ entry: HistoryEntry) {
        replay(entry)
    }

    public func delete(_ entry: HistoryEntry) async {
        await perform("ReadBack did not delete the entry.") { try await $0.delete(id: entry.id) }
    }

    /// Asks for confirmation before `clear()`. An empty list has nothing to confirm.
    public func requestClear() {
        isConfirmingClear = !entries.isEmpty
    }

    public func cancelClear() {
        isConfirmingClear = false
    }

    public func clear() async {
        isConfirmingClear = false
        await perform("ReadBack did not clear history.") { try await $0.clear() }
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
    public var displayName: String {
        switch self {
        case .agent(let host?): "Agent · \(host)"
        case .agent(nil): "Agent"
        case .clipboard: "Clipboard"
        case .voicepipe: "voicepipe"
        }
    }
}
