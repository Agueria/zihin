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
                // .remove (remove_diacritics=2) GRDBCIPHER build'lerinde derlenmiyor;
                // SQLCipher fork'unda diakritik temizleyen tek seçenek .removeLegacy.
                t.tokenizer = .unicode61(diacritics: .removeLegacy)
            }
        }

        // v2 (spec §4.2): anlam katmanı, taksonomi, kavram grafiği, materyalize üyelik.
        m.registerMigration("v2") { db in
            // (a) Model versiyonlama + lemma gölge kolonu (§4.1a / §4.7)
            try db.alter(table: "item") { t in
                t.add(column: "embeddingModel", .text)
                t.add(column: "embeddingRevision", .integer)
                t.add(column: "lemmaText", .text)
            }
            // Etiket tipi (§4.3) — graph/space yalnız topic'e bakar
            try db.alter(table: "tag") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "keyword")
            }
            // Space üyeliği materyalize (§4.4). DİKKAT: item_space ZATEN var → ALTER
            try db.alter(table: "item_space") { t in
                t.add(column: "source", .text).notNull().defaults(to: "manual")
                t.add(column: "excluded", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "space") { t in
                t.add(column: "rule", .text)
                t.add(column: "threshold", .double)
            }
            // (c) Chunk vektörleri (§4.1c)
            try db.create(table: "item_chunk") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.primaryKey(["itemId", "idx"])
            }
            // Taksonomi (§4.3)
            try db.create(table: "topic") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentId", .text).references("topic")
                t.column("isCore", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "topic_phrase") { t in
                t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
                t.column("phrase", .text).notNull()
            }
            try db.create(table: "item_topic") { t in
                t.column("itemId", .text).notNull().references("item", onDelete: .cascade)
                t.column("topicId", .text).notNull().references("topic", onDelete: .cascade)
                t.column("score", .double).notNull()
                t.column("source", .text).notNull()
                t.primaryKey(["itemId", "topicId"])
            }
            // Kavram grafiği (§4.6)
            try db.create(table: "graph_position") { t in
                t.column("nodeKey", .text).primaryKey()
                t.column("x", .double)
                t.column("y", .double)
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "manual_edge") { t in
                t.column("id", .text).primaryKey()
                t.column("aKey", .text).notNull()          // DAİMA aKey < bKey normalize edilir
                t.column("bKey", .text).notNull()
                t.column("origin", .text).notNull()        // user|suggested
                t.column("batchId", .text)                 // toplu geri alma
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["aKey", "bKey"])              // çift kenar imkânsız
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
            // (b) μ + model durumu (§4.1b)
            try db.create(table: "embedding_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("vector", .blob)
                t.column("count", .integer)
                t.column("model", .text)
                t.column("revision", .integer)
            }
            // FTS5 yeniden kur: lemmaText kolonu ekle (§4.2). bm25 ağırlıkları sorgu anında (§4.7).
            // Eski synchronize trigger'ları item tablosunda; adlarında "item_fts" geçenleri düşür.
            let oldTriggers = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'item'")
            for name in oldTriggers where name.contains("item_fts") {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \"\(name)\"")
            }
            try db.execute(sql: "DROP TABLE IF EXISTS item_fts")
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.column("title")
                t.column("summary")
                t.column("textContent")
                t.column("transcript")
                t.column("ocrText")
                t.column("frameText")
                t.column("lemmaText")
                t.tokenizer = .unicode61(diacritics: .removeLegacy)
            }
            // Mevcut tüm embedding'ler çöp (§2.1) → sessiz reindex (§4.8)
            try db.execute(sql: "UPDATE item SET status = 'pending', embedding = NULL, dirty = 1")
        }
        return m
    }
}
