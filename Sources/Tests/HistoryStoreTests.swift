import Foundation
import ReadBackCore
import SQLite3

/// Returns a history file in a new temporary directory. Remove it with
/// `removeHistoryDirectory(of:)`.
func makeHistoryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("readback-history-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("history.sqlite")
}

/// Returns a history file whose parent is a regular file, so the store can never open it.
func makeUnopenableHistoryFileURL() throws -> URL {
    let blocker = FileManager.default.temporaryDirectory
        .appendingPathComponent("readback-history-blocker-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blocker)
    return blocker.appendingPathComponent("history.sqlite")
}

func removeHistoryDirectory(of file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
}

func historyStoreTests() -> [TestCase] {
    [
        TestCase(name: "history store creates a user-only database at schema version 1") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)

            try await store.insert("Hello.", source: .clipboard, at: Date())

            for suffix in ["", "-wal", "-shm"] {
                let path = file.path + suffix
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let mode = try permissions(atPath: path)
                try expectEqual(mode, 0o600, "permissions of history.sqlite\(suffix)")
            }
            let version = try userVersion(at: file)
            try expectEqual(version, 1, "schema version")
        },
        TestCase(name: "history store tightens permissions on an existing database") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            try await HistoryStore(fileURL: file).insert("Hello.", source: .clipboard, at: Date())
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

            _ = try await HistoryStore(fileURL: file).entries()

            let mode = try permissions(atPath: file.path)
            try expectEqual(mode, 0o600, "reopened database permissions")
        },
        TestCase(name: "history store lists entries newest first with source and time") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            try await store.insert("From the clipboard.", source: .clipboard, at: start)
            try await store.insert("From Cursor.", source: .agent(host: "Cursor"), at: start + 1)
            try await store.insert("From an agent.", source: .agent(host: nil), at: start + 2)
            try await store.insert("From voicepipe.", source: .voicepipe, at: start + 3)

            let entries = try await store.entries()
            try expectEqual(
                entries.map(\.text),
                ["From voicepipe.", "From an agent.", "From Cursor.", "From the clipboard."],
                "newest first"
            )
            try expectEqual(
                entries.map(\.source),
                [.voicepipe, .agent(host: nil), .agent(host: "Cursor"), .clipboard],
                "sources"
            )
            try expectEqual(entries.last?.createdAt, start, "saved time")
        },
        TestCase(name: "history store appends streamed text to an entry") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)

            let id = try await store.insert("Hello", source: .voicepipe, at: Date())
            try await store.append(", world.", to: id)

            let appended = try await store.entries()
            try expectEqual(appended.map(\.text), ["Hello, world."], "appended text")
            do {
                try await store.append("lost", to: id + 1)
                throw TestFailure(description: "appending to a missing entry should fail")
            } catch let error as HistoryStoreError {
                try expectEqual(error, .entryNotFound(id + 1), "missing entry error")
            }
        },
        TestCase(name: "history store keeps only the newest entries") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file, maximumEntries: 3)

            for number in 1...5 {
                try await store.insert("Entry \(number)", source: .clipboard, at: Date())
            }

            let entries = try await store.entries()
            try expectEqual(entries.map(\.text), ["Entry 5", "Entry 4", "Entry 3"], "pruned entries")
        },
        TestCase(name: "history store deletes one entry and clears all without reusing ids") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)
            let first = try await store.insert("First", source: .clipboard, at: Date())
            let second = try await store.insert("Second", source: .clipboard, at: Date())
            try await store.insert("Third", source: .clipboard, at: Date())

            try await store.delete(id: second)
            let afterDelete = try await store.entries()
            try expectEqual(afterDelete.map(\.text), ["Third", "First"], "after delete")

            try await store.clear()
            let afterClear = try await store.entries()
            try expectEqual(afterClear, [], "after clear")

            let next = try await store.insert("Fourth", source: .clipboard, at: Date())
            try expect(next > first + 2, "ids are not reused after clearing")
        },
        TestCase(name: "history store keeps entries across reopening") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            try await HistoryStore(fileURL: file).insert("Kept.", source: .voicepipe, at: Date())

            let reopened = try await HistoryStore(fileURL: file).entries()

            try expectEqual(reopened.map(\.text), ["Kept."], "reopened entries")
        },
        TestCase(name: "history store saves quotes, SQL and NUL characters verbatim") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)
            let text = "Robert'); DROP TABLE entries;-- \"quoted\" a\u{0}b 🐦"

            let id = try await store.insert(text, source: .agent(host: "it's"), at: Date())
            try await store.append(" ' OR 1=1", to: id)

            let entries = try await store.entries()
            try expectEqual(entries.map(\.text), [text + " ' OR 1=1"], "stored text")
            try expectEqual(entries.map(\.source), [.agent(host: "it's")], "stored host")
        },
        TestCase(name: "history store refuses a database from a newer version") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try setUserVersion(2, at: file)

            do {
                _ = try await HistoryStore(fileURL: file).entries()
                throw TestFailure(description: "a newer schema should be refused")
            } catch let error as HistoryStoreError {
                try expectEqual(
                    error,
                    .unsupportedSchemaVersion(path: file.path, found: 2, supported: 1),
                    "schema error"
                )
            }
            let version = try userVersion(at: file)
            try expectEqual(version, 2, "newer database left untouched")
        },
        TestCase(name: "history store reports a file that is not a database, then recovers") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x2A, count: 4_096).write(to: file)
            let store = HistoryStore(fileURL: file)

            do {
                _ = try await store.entries()
                throw TestFailure(description: "a damaged file should fail to open")
            } catch let error as HistoryStoreError {
                guard case .openFailed(let path, let reason) = error else {
                    throw TestFailure(description: "expected openFailed, got \(error)")
                }
                try expectEqual(path, file.path, "failing path")
                try expect(!reason.isEmpty, "the reason explains the failure")
                try expect(
                    error.localizedDescription.contains(file.path),
                    "the message names the file"
                )
            }

            try FileManager.default.removeItem(at: file)
            try await store.insert("Works again.", source: .clipboard, at: Date())
            let recovered = try await store.entries()
            try expectEqual(recovered.map(\.text), ["Works again."], "recovered store")
        },
        TestCase(name: "history store reports a location it cannot create") {
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }

            do {
                try await HistoryStore(fileURL: file).insert("Lost.", source: .clipboard, at: Date())
                throw TestFailure(description: "an impossible location should fail")
            } catch let error as HistoryStoreError {
                guard case .openFailed(let path, _) = error else {
                    throw TestFailure(description: "expected openFailed, got \(error)")
                }
                try expectEqual(path, file.path, "failing path")
            }
        },
        TestCase(name: "history store announces changes") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)
            var changes = await store.changes().makeAsyncIterator()

            try await store.insert("Changed.", source: .clipboard, at: Date())

            let change: Void? = await changes.next()
            try expect(change != nil, "insert is announced")
        },
    ]
}

private func permissions(atPath path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let value = attributes[.posixPermissions] as? NSNumber else {
        throw TestFailure(description: "missing permissions for \(path)")
    }
    return value.intValue
}

private func withDatabase<Result>(
    at file: URL,
    _ body: (OpaquePointer) throws -> Result
) throws -> Result {
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else {
        throw TestFailure(description: "could not open \(file.path) for inspection")
    }
    defer { sqlite3_close(db) }
    return try body(db)
}

private func userVersion(at file: URL) throws -> Int32 {
    try withDatabase(at: file) { db in
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            throw TestFailure(description: "could not read user_version")
        }
        return sqlite3_column_int(statement, 0)
    }
}

private func setUserVersion(_ version: Int32, at file: URL) throws {
    try withDatabase(at: file) { db in
        guard sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(description: "could not set user_version")
        }
    }
}
