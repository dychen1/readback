import Combine
import Foundation

/// Behaviour behind the History window. Views stay thin, so a new visual design can reuse
/// this model unchanged.
@MainActor
public final class HistoryListModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case loaded([HistoryEntry])
        case unavailable(String)
    }

    @Published public private(set) var state: State = .loading
    /// Why the last delete or clear failed; reset by the next successful one.
    @Published public private(set) var actionError: String?
    @Published public private(set) var isConfirmingClear = false

    private let store: HistoryStore
    private let replay: @MainActor (HistoryEntry) -> Void

    public init(store: HistoryStore, replay: @escaping @MainActor (HistoryEntry) -> Void) {
        self.store = store
        self.replay = replay
    }

    /// Entries newest first; empty while loading or unavailable.
    public var entries: [HistoryEntry] {
        if case .loaded(let entries) = state { entries } else { [] }
    }

    public func refresh() async {
        do {
            state = .loaded(try await store.entries())
        } catch {
            state = .unavailable("History is unavailable. \(error.localizedDescription)")
        }
    }

    /// Keeps the list current until the calling task is cancelled, e.g. by a view's `.task`.
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
        await perform("delete the entry") { try await $0.delete(id: entry.id) }
    }

    /// Asks for confirmation before `clear()`; there is nothing to confirm for an empty list.
    public func requestClear() {
        isConfirmingClear = !entries.isEmpty
    }

    public func cancelClear() {
        isConfirmingClear = false
    }

    public func clear() async {
        isConfirmingClear = false
        await perform("clear history") { try await $0.clear() }
    }

    private func perform(
        _ action: String,
        _ change: (HistoryStore) async throws -> Void
    ) async {
        do {
            try await change(store)
            actionError = nil
        } catch {
            actionError = "Could not \(action): \(error.localizedDescription)"
        }
        await refresh()
    }
}

extension HistoryEntry {
    /// The first non-blank line, trimmed, for one-line list rows.
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
