import Foundation
import GRDB

/// App Group içindeki tek SQLite dosyası (app + extension ortak).
final class DatabaseManager: Sendable {
    static let shared = try! DatabaseManager()
    let dbPool: DatabasePool

    static let appGroupID = "group.app.zihin"
    private static let dbFileName = "zihin.sqlite"

    enum DBError: Error { case noAppGroup }

    init() throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw DBError.noAppGroup
        }
        let dbURL = container.appendingPathComponent(Self.dbFileName)

        var config = Configuration()
        config.foreignKeysEnabled = true
        // E3: SQLCipher (DuckDuckGo GRDB fork + ZIHIN_ENCRYPTED bayrağı, bkz. docs/SETUP_MAC.md)
        #if ZIHIN_ENCRYPTED
        config.prepareDatabase { db in
            try db.usePassphrase(KeychainKey.databasePassphrase())
        }
        #endif

        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("title", .text)
                t.column("url", .text)
                t.column("textContent", .text)
                t.column("readerHTML", .text)
                t.column("summary", .text)
                t.column("ocrText", .text)
                t.column("transcript", .text)
                t.column("frameText", .text)
                t.column("assetPath", .text)
                t.column("posterPath", .text)
                t.column("dominantColors", .text)
                t.column("durationSec", .double)
                t.column("siteName", .text)
                t.column("lang", .text)
                t.column("enrichAttempts", .integer).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("forgotten", .boolean).notNull().defaults(to: false)
                t.column("embedding", .blob)
                t.column("featurePrint", .blob)
                t.column("ckSystemFields", .blob)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "tag") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().collate(.nocase)
                t.column("source", .text).notNull()
                t.uniqueKey(["name"])
            }
            try db.create(table: "item_tag") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["itemId", "tagId"])
            }
            try db.create(table: "space") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("isSmart", .boolean).notNull().defaults(to: false)
                t.column("query", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "item_space") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("spaceId", .text).notNull().references("space", onDelete: .cascade)
                t.primaryKey(["itemId", "spaceId"])
            }
            try db.create(table: "meta_field") { t in
                t.column("id", .text).primaryKey()
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
            }
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.column("title")
                t.column("textContent")
                t.column("ocrText")
                t.column("summary")
                t.column("transcript")
                t.column("frameText")
                t.tokenizer = .unicode61(diacritics: .remove)
            }
        }
        return m
    }
}
