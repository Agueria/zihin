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

        // === v1: temel tablolar ===
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
                // .remove (remove_diacritics=2) GRDBCIPHER build'lerinde derlenmiyor;
                // SQLCipher fork'unda diakritik temizleyen tek seçenek .removeLegacy.
                t.tokenizer = .unicode61(diacritics: .removeLegacy)
            }
        }

        // === v2: anlam katmanı, space kuralları, kavram grafiği ===
        m.registerMigration("v2") { db in
            // --- item: model versiyonlama, lemma ---
            try db.alter(table: "item") { t in
                t.addColumn("embeddingModel").to(.text).optional()
                t.addColumn("embeddingRevision").to(.integer).optional()
                t.addColumn("lemmaText").to(.text).optional()
            }

            // --- item_chunk: parçalı embedding'ler ---
            try db.create(table: "item_chunk") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.primaryKey(["itemId", "idx"])
            }

            // --- tag: tip ---
            try db.alter(table: "tag") { t in
                t.addColumn("kind").to(.text).notNull().defaults(to: "keyword")
            }

            // --- topic taksonomisi ---
            try db.create(table: "topic") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentId", .text).references("topic", onDelete: .cascade).optional()
                t.column("isCore", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "topic_phrase") { t in
                t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
                t.column("phrase", .text).notNull()
            }
            try db.create(table: "item_topic") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
                t.column("score", .real).notNull()
                t.column("source", .text).notNull()
                t.primaryKey(["itemId", "topicId"])
            }

            // --- space üyelik zenginleştirme ---
            try db.alter(table: "item_space") { t in
                t.addColumn("source").to(.text).notNull().defaults(to: "manual")
                t.addColumn("excluded").to(.boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "space") { t in
                t.addColumn("rule").to(.text).optional()
                t.addColumn("threshold").to(.double).optional()
            }

            // --- kavram grafiği ---
            try db.create(table: "graph_position") { t in
                t.column("id", .text).primaryKey()
                t.column("nodeKey", .text).notNull().unique()
                t.column("x", .real).notNull().defaults(to: 0)
                t.column("y", .real).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "manual_edge") { t in
                t.column("id", .text).primaryKey()
                t.column("aKey", .text).notNull()
                t.column("bKey", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("batchId", .text).optional()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["aKey", "bKey"])
            }
            try db.create(table: "profile_node") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
            }
            try db.create(table: "profile_topic") { t in
                t.column("profileId", .text).notNull().references("profile_node", onDelete: .cascade)
                t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
                t.primaryKey(["profileId", "topicId"])
            }

            // --- embedding_meta: korpus ortalaması + model bilgisi ---
            try db.create(table: "embedding_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("vector", .blob).notNull()     // donmuş μ
                t.column("count", .integer).notNull()    // birikim sayaç
                t.column("model", .text).notNull()
                t.column("revision", .integer).notNull()
            }

            // --- item_fts: lemma kolonu + bm25 ağırlıkları ---
            // GRDB FTS5 synchronize ile tabloyu yeniden oluşturmak için drop+create gerekir
            try db.execute(sql: "DROP TABLE IF EXISTS item_fts")
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.column("title", weight: 10.0)
                t.column("summary", weight: 5.0)
                t.column("textContent", weight: 1.0)
                t.column("transcript", weight: 0.5)
                t.column("ocrText", weight: 0.3)
                t.column("frameText", weight: 0.3)
                t.column("lemmaText")
                t.tokenizer = .unicode61(diacritics: .removeLegacy)
            }
        }

        return m
    }
}
