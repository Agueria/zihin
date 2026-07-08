import Foundation
import GRDB

// v2 (spec §4.2/§4.3/§4.6) — taksonomi, kavram grafiği ve μ için GRDB kayıtları.
// Hepsi Sendable + Codable; DatabasePool üzerinden okunur/yazılır.

/// Hibrit taksonomi düğümü. `isCore` = küratörlü çekirdek (bundle JSON),
/// `isCore = false` = keşif katmanının önerdiği, kullanıcıya ait konu (§4.3).
struct Topic: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    var parentId: String?
    var isCore: Bool = false
    var createdAt: Date = Date()
    static let databaseTableName = "topic"
}

/// Konu prototipini besleyen TR/EN ifadeler (merkezlenmiş vektör ortalaması).
struct TopicPhrase: Codable, Sendable, FetchableRecord, PersistableRecord {
    var topicId: String
    var phrase: String
    static let databaseTableName = "topic_phrase"
}

/// Item ↔ konu ataması. `source`: lexicon|embedding|llm|manual (§4.3).
struct ItemTopic: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var topicId: String
    var score: Double
    var source: String
    static let databaseTableName = "item_topic"
}

/// ~200 token'lık pencere vektörü (§4.1c). Arama chunk düzeyinde max-pool.
struct ItemChunk: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var idx: Int
    var vector: Data                     // [Float] little-endian
    static let databaseTableName = "item_chunk"
}

/// Yönsüz manuel/önerilen kenar. DAİMA aKey < bKey normalize (§4.2).
/// `origin`: user|suggested. `batchId`: toplu geri alma.
struct ManualEdge: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var aKey: String
    var bKey: String
    var origin: String                   // user|suggested
    var batchId: String?
    var createdAt: Date = Date()
    static let databaseTableName = "manual_edge"
}

/// Sürüklenen düğümün sabitlenmiş konumu (§4.6). `pinned` → layout dokunmaz.
struct GraphPosition: Codable, Sendable, FetchableRecord, PersistableRecord {
    var nodeKey: String                  // "item:<uuid>" | "topic:<uuid>" | "profile:<uuid>"
    var x: Double?
    var y: Double?
    var pinned: Bool = false
    static let databaseTableName = "graph_position"
}

/// "Meslek: yazılımcı" gibi BEYAN edilen düğüm (§4.6) — nottan türetilemez.
struct ProfileNode: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    static let databaseTableName = "profile_node"
}

struct ProfileTopic: Codable, Sendable, FetchableRecord, PersistableRecord {
    var profileId: String
    var topicId: String
    static let databaseTableName = "profile_topic"
}

/// μ ve model durumu (§4.1b). `key`: "sum" (sürekli biriken Σv) | "frozen" (donmuş μ).
struct EmbeddingMeta: Codable, Sendable, FetchableRecord, PersistableRecord {
    var key: String
    var vector: Data?                    // [Float] little-endian
    var count: Int?
    var model: String?
    var revision: Int?
    static let databaseTableName = "embedding_meta"
}

/// nodeKey yardımcıları — tip düzeyinde tutarlı anahtar üretimi (§4.2).
enum NodeKey {
    static func item(_ id: String) -> String { "item:\(id)" }
    static func topic(_ id: String) -> String { "topic:\(id)" }
    static func profile(_ id: String) -> String { "profile:\(id)" }
}
