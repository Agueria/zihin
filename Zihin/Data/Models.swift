import Foundation
import GRDB

// MARK: - Route (F1: String çakışmasını çözer, tip düzeyinde imkansız)
enum Route: Hashable {
    case item(String)
    case space(String)
}

// MARK: - TagKind (F2: etiket tiplerini ayırır — renk keyword değil)
enum TagKind: String, Codable, Sendable {
    case topic, entity, color, keyword
}

enum ItemType: String, Codable, CaseIterable, Sendable {
    case note, quote, link, image, pdf, video
}

/// İki aşamalı capture durum makinesi (spec §3.3).
enum ItemStatus: String, Codable, Sendable {
    case pending, enriching, ready, failed
}

struct Item: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var type: ItemType
    var status: ItemStatus = .pending
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var title: String?
    var url: String?
    var textContent: String?
    var readerHTML: String?
    var summary: String?
    var ocrText: String?
    var transcript: String?
    var frameText: String?
    var assetPath: String?
    var posterPath: String?
    var dominantColors: String?          // JSON [String]
    var durationSec: Double?
    var siteName: String?
    var lang: String?
    var enrichAttempts: Int = 0
    var isPinned: Bool = false
    var forgotten: Bool = false
    var embedding: Data?                 // [Float] little-endian
    var featurePrint: Data?              // VNFeaturePrintObservation archive
    var ckSystemFields: Data?            // CloudKit (Faz 3)
    var dirty: Bool = true
    // F0: model versiyonlama — model değişirse sessiz bozulmayı önler
    var embeddingModel: String?
    var embeddingRevision: Int?
    // F0: lemma gölge kolonu (NLTagger .lemma)
    var lemmaText: String?

    static let databaseTableName = "item"

    var colors: [String] {
        get { (try? JSONDecoder().decode([String].self,
               from: Data((dominantColors ?? "[]").utf8))) ?? [] }
        set { dominantColors = String(data: (try? JSONEncoder().encode(newValue)) ?? Data(),
                                      encoding: .utf8) }
    }
}

struct Tag: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    var source: String = "auto"          // "auto" | "manual"
    var kind: TagKind = .keyword         // F0: topic|entity|color|keyword
    static let databaseTableName = "tag"
}

struct ItemTag: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var tagId: String
    static let databaseTableName = "item_tag"
}

struct Space: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    var isSmart: Bool = false
    var query: String?                   // smart space kayıtlı arama
    var createdAt: Date = Date()
    // F0: semantic üyelik kuralları
    var rule: String?                    // deterministic rule (topic:ai AND type:note)
    var threshold: Double?               // cosine threshold for semantic membership
    static let databaseTableName = "space"
}

struct ItemSpace: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var spaceId: String
    // F0: üyelik kaynağı + "bu değil" bayrağı
    var source: String = "manual"        // manual|rule|semantic
    var excluded: Bool = false           // kullanıcı "bu buraya ait değil" dediyse
    static let databaseTableName = "item_space"
}

struct MetaField: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var itemId: String
    var key: String
    var value: String
    static let databaseTableName = "meta_field"
}

// MARK: - Topic Taksonomisi (F0, F2)
struct Topic: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    var parentId: String?                // hiyerarşik taksonomi
    var isCore: Bool = true              // küratörlü mü, keşfedilmiş mi
    var createdAt: Date = Date()
    static let databaseTableName = "topic"
}

struct TopicPhrase: Codable, Sendable, FetchableRecord, PersistableRecord {
    var topicId: String
    var phrase: String
    static let databaseTableName = "topic_phrase"
}

struct ItemTopic: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var topicId: String
    var score: Double
    var source: String                   // lexicon|embedding|llm|manual
    static let databaseTableName = "item_topic"
}

// MARK: - Item Chunking (F0: 256 token sınırı nedeniyle parçalama)
struct ItemChunk: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var idx: Int
    var vector: Data                     // [Float] little-endian
    static let databaseTableName = "item_chunk"
}

// MARK: - Concept Graph (F3)
struct ManualEdge: Codable, Sendable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var aKey: String                     // normalized: aKey < bKey
    var bKey: String
    var origin: String                   // user|suggested
    var batchId: String?                 // toplu geri alma için
    var createdAt: Date = Date()
    static let databaseTableName = "manual_edge"
}

struct GraphPosition: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var nodeKey: String                  // "item:<id>", "topic:<id>", "profile:<id>"
    var x: Double = 0
    var y: Double = 0
    var pinned: Bool = false
    static let databaseTableName = "graph_position"
}

// MARK: - Profile Nodes (F3: kullanıcı profili — meslek, ilgi alanları)
struct ProfileNode: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var name: String                     // "Meslek: yazılımcı"
    static let databaseTableName = "profile_node"
}

struct ProfileTopic: Codable, Sendable, FetchableRecord, PersistableRecord {
    var profileId: String
    var topicId: String
    static let databaseTableName = "profile_topic"
}
