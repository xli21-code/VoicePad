import Foundation
import GRDB

/// A single transcript entry.
struct TranscriptEntry: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var text: String
    var language: String?
    var duration: TimeInterval
    var translatedText: String?

    static let databaseTableName = "transcripts"
}

/// SQLite-backed transcript history with FTS5 full-text search.
final class HistoryStore {
    private var dbQueue: DatabaseQueue?
    private let maxEntries = 10_000

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbDir = home.appendingPathComponent(".voicepad")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("history.sqlite").path

        do {
            var config = Configuration()
            config.prepareDatabase { db in
                db.trace { print("SQL: \($0)") }
            }
            dbQueue = try DatabaseQueue(path: dbPath)
            try setupDatabase()
        } catch {
            print("HistoryStore: failed to open database: \(error)")
            dbQueue = nil
        }
    }

    private func setupDatabase() throws {
        try dbQueue?.write { db in
            try db.create(table: "transcripts", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("text", .text).notNull()
                t.column("language", .text)
                t.column("duration", .double).notNull()
                t.column("translatedText", .text)
            }

            // FTS5 virtual table for full-text search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts
                USING fts5(text, translatedText, content=transcripts, content_rowid=rowid)
            """)

            // Triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
                    INSERT INTO transcripts_fts(rowid, text, translatedText)
                    VALUES (new.rowid, new.text, new.translatedText);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, text, translatedText)
                    VALUES ('delete', old.rowid, old.text, old.translatedText);
                END
            """)
        }
    }

    func append(_ entry: TranscriptEntry) {
        do {
            try dbQueue?.write { db in
                var record = entry
                try record.insert(db)
            }
            prune()
        } catch {
            print("HistoryStore: insert failed: \(error)")
        }
    }

    func search(query: String) -> [TranscriptEntry] {
        (try? dbQueue?.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
            // Search FTS and join back to get full records
            let sql = """
                SELECT transcripts.* FROM transcripts
                JOIN transcripts_fts ON transcripts.rowid = transcripts_fts.rowid
                WHERE transcripts_fts MATCH ?
                ORDER BY transcripts.timestamp DESC
                LIMIT 50
            """
            return try TranscriptEntry.fetchAll(db, sql: sql, arguments: [pattern?.rawPattern ?? query])
        }) ?? []
    }

    func recent(limit: Int) -> [TranscriptEntry] {
        (try? dbQueue?.read { db in
            try TranscriptEntry
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    private func prune() {
        try? dbQueue?.write { db in
            let count = try TranscriptEntry.fetchCount(db)
            guard count > maxEntries else { return }

            let excess = count - maxEntries
            try db.execute(sql: """
                DELETE FROM transcripts WHERE id IN (
                    SELECT id FROM transcripts ORDER BY timestamp ASC LIMIT ?
                )
            """, arguments: [excess])
        }
    }
}
