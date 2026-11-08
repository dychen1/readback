import Foundation
import SQLite3

public enum HistorySource: Equatable, Sendable {
    case agent(host: String?)
    case clipboard
    case voicepipe
}

public struct HistoryEntry: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let source: HistorySource
    public let text: String

    public init(id: Int64, createdAt: Date, source: HistorySource, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.text = text
    }
}

public enum HistoryStoreError: Error, Equatable, LocalizedError {
    case openFailed(path: String, reason: String)
    case unsupportedSchemaVersion(path: String, found: Int32, supported: Int32)
    case sqliteFailed(operation: String, reason: String)
    case entryNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason):
            "Could not open \(path): \(reason)"
        case .unsupportedSchemaVersion(let path, let found, let supported):
            "\(path) uses history format \(found), but this version of ReadBack reads up to format \(supported)."
        case .sqliteFailed(let operation, let reason):
            "Could not \(operation): \(reason)"
        case .entryNotFound(let id):
            "History entry \(id) no longer exists."
        }
    }
}

/// Spoken-text history in a user-only SQLite file.
///
/// The database opens on first use. A failed open is retried on the next call, so a damaged
/// or unreadable file makes history unavailable without affecting speech.
public actor HistoryStore {
    public static let defaultMaximumEntries = 200
    static let schemaVersion: Int32 = 1

    public nonisolated let fileURL: URL
    public nonisolated let maximumEntries: Int
    private var connection: Connection?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(fileURL: URL, maximumEntries: Int = defaultMaximumEntries) {
        precondition(maximumEntries > 0)
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
    }

    /// Saves a new entry and drops the oldest entries beyond `maximumEntries`.
    @discardableResult
    public func insert(_ text: String, source: HistorySource, at date: Date) throws -> Int64 {
        let db = try openIfNeeded()
        let operation = "save a history entry"
        let id = try transaction(db, operation: operation) {
            try run(
                db,
                "INSERT INTO entries (created_at, source, agent_host, text) VALUES (?, ?, ?, ?)",
                [.real(date.timeIntervalSince1970), .text(source.storedKind), .text(source.agentHost), .text(text)],
                operation: operation
            )
            let id = sqlite3_last_insert_rowid(db)
            try run(
                db,
                "DELETE FROM entries WHERE id <= (SELECT id FROM entries ORDER BY id DESC LIMIT 1 OFFSET ?)",
                [.integer(Int64(maximumEntries))],
                operation: operation
            )
            return id
        }
        notifyChanged()
        return id
    }

    public func append(_ text: String, to id: Int64) throws {
        let db = try openIfNeeded()
        try run(
            db,
            "UPDATE entries SET text = text || ? WHERE id = ?",
            [.text(text), .integer(id)],
            operation: "update a history entry"
        )
        guard sqlite3_changes(db) > 0 else {
            throw HistoryStoreError.entryNotFound(id)
        }
        notifyChanged()
    }

    /// All entries, newest first.
    public func entries() throws -> [HistoryEntry] {
        let db = try openIfNeeded()
        let operation = "read history"
        var entries: [HistoryEntry] = []
        try run(
            db,
            "SELECT id, created_at, source, agent_host, text FROM entries ORDER BY id DESC",
            operation: operation
        ) { row in
            let kind = Self.columnText(row, 2) ?? ""
            guard let source = HistorySource(storedKind: kind, agentHost: Self.columnText(row, 3)) else {
                throw HistoryStoreError.sqliteFailed(
                    operation: operation,
                    reason: "unknown source \"\(kind)\""
                )
            }
            entries.append(
                HistoryEntry(
                    id: sqlite3_column_int64(row, 0),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    source: source,
                    text: Self.columnText(row, 4) ?? ""
                )
            )
        }
        return entries
    }

    public func delete(id: Int64) throws {
        let db = try openIfNeeded()
        try run(db, "DELETE FROM entries WHERE id = ?", [.integer(id)], operation: "delete a history entry")
        checkpoint(db)
        notifyChanged()
    }

    public func clear() throws {
        let db = try openIfNeeded()
        try run(db, "DELETE FROM entries", operation: "clear history")
        checkpoint(db)
        notifyChanged()
    }

    /// Yields after every change to the stored entries. Bursts coalesce into one element.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return stream
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations[id] = nil
    }

    private func notifyChanged() {
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    // MARK: - Opening

    private final class Connection {
        let handle: OpaquePointer

        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        deinit {
            sqlite3_close_v2(handle)
        }
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection.handle }
        let path = fileURL.path
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw HistoryStoreError.openFailed(path: path, reason: error.localizedDescription)
        }
        if !fileManager.fileExists(atPath: path),
           !fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        {
            throw HistoryStoreError.openFailed(path: path, reason: "the file could not be created")
        }

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let handle else {
            let reason = handle.map(Self.errorMessage) ?? String(cString: sqlite3_errstr(result))
            sqlite3_close_v2(handle)
            throw HistoryStoreError.openFailed(path: path, reason: reason)
        }
        let opened = Connection(handle)
        do {
            try prepare(handle)
            try restrictPermissions()
        } catch {
            if case .sqliteFailed(_, let reason) = error as? HistoryStoreError {
                throw HistoryStoreError.openFailed(path: path, reason: reason)
            }
            throw error
        }
        connection = opened
        return handle
    }

    private func prepare(_ db: OpaquePointer) throws {
        let operation = "open history"
        sqlite3_busy_timeout(db, 2_000)
        var version: Int32 = 0
        try run(db, "PRAGMA user_version", operation: operation) { row in
            version = sqlite3_column_int(row, 0)
        }
        try run(db, "PRAGMA journal_mode = WAL", operation: operation)
        try run(db, "PRAGMA synchronous = NORMAL", operation: operation)
        try run(db, "PRAGMA secure_delete = ON", operation: operation)

        if version == Self.schemaVersion { return }
        guard version == 0 else {
            throw HistoryStoreError.unsupportedSchemaVersion(
                path: fileURL.path,
                found: version,
                supported: Self.schemaVersion
            )
        }
        try transaction(db, operation: operation) {
            try run(
                db,
                """
                CREATE TABLE entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    source TEXT NOT NULL CHECK (source IN ('agent', 'clipboard', 'voicepipe')),
                    agent_host TEXT,
                    text TEXT NOT NULL
                )
                """,
                operation: operation
            )
            try run(db, "PRAGMA user_version = 1", operation: operation)
        }
    }

    private func restrictPermissions() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            if chmod(path, 0o600) != 0, errno != ENOENT {
                throw HistoryStoreError.openFailed(
                    path: path,
                    reason: "could not restrict permissions: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    // MARK: - SQLite helpers

    private enum Value {
        case integer(Int64)
        case real(Double)
        case text(String?)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func run(
        _ db: OpaquePointer,
        _ sql: String,
        _ values: [Value] = [],
        operation: String,
        onRow: (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.sqliteFailed(operation: operation, reason: Self.errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let text?):
                text.withCString { pointer in
                    sqlite3_bind_text64(
                        statement,
                        index,
                        pointer,
                        sqlite3_uint64(text.utf8.count),
                        Self.transient,
                        UInt8(SQLITE_UTF8)
                    )
                }
            case .text(nil):
                sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw HistoryStoreError.sqliteFailed(operation: operation, reason: Self.errorMessage(db))
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try onRow(statement)
            case SQLITE_DONE:
                return
            default:
                throw HistoryStoreError.sqliteFailed(operation: operation, reason: Self.errorMessage(db))
            }
        }
    }

    private func transaction<Result>(
        _ db: OpaquePointer,
        operation: String,
        _ body: () throws -> Result
    ) throws -> Result {
        try run(db, "BEGIN IMMEDIATE", operation: operation)
        do {
            let result = try body()
            try run(db, "COMMIT", operation: operation)
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func checkpoint(_ db: OpaquePointer) {
        // Deleted text otherwise stays in the WAL file until SQLite's next automatic
        // checkpoint. A failure here leaves the delete itself intact.
        try? run(db, "PRAGMA wal_checkpoint(TRUNCATE)", operation: "checkpoint history")
    }

    private static func columnText(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, index) else { return nil }
        let count = Int(sqlite3_column_bytes(row, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

extension HistorySource {
    var storedKind: String {
        switch self {
        case .agent: "agent"
        case .clipboard: "clipboard"
        case .voicepipe: "voicepipe"
        }
    }

    var agentHost: String? {
        if case .agent(let host) = self { host } else { nil }
    }

    init?(storedKind: String, agentHost: String?) {
        switch storedKind {
        case "agent": self = .agent(host: agentHost)
        case "clipboard": self = .clipboard
        case "voicepipe": self = .voicepipe
        default: return nil
        }
    }
}
