import Foundation
import GRDB

enum ItemType: String, Codable, CaseIterable, Sendable {
    case note, quote, link, image, pdf, video
}

/// İki aşamalı capture durum makinesi (spec §3.3).
enum ItemStatus: String, Codable, Sendable {
    case pending, enriching, ready, failed
}

/// Etiket tipi (v2 spec §4.3). Graph ve space'ler YALNIZ `.topic`'e bakar;
/// `.color` ("mavi") ve `.keyword` (RAKE) artık anlamsal bağ üretmez.
enum TagKind: String, Codable, Sendable {
    case topic, entity, color, keyword
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
    var embedding: Data?                 // [Float] little-endian (doküman ortalaması)
    var featurePrint: Data?              // VNFeaturePrintObservation archive
    var ckSystemFields: Data?            // CloudKit (Faz 3)
    var dirty: Bool = true
    // v2: model versiyonlama (§4.1a) — uyuşmazlık reindex tetikler, çökme değil.
    var embeddingModel: String?
    var embeddingRevision: Int?
    // v2: NLTagger(.lemma) gölge kolonu (§4.7) — `yazılımcı` ≡ `yazılım` aramada.
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
    var kind: String = TagKind.keyword.rawValue   // v2: topic|entity|color|keyword
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
    var query: String?                   // smart space kayıtlı arama (v1, korunur)
    var createdAt: Date = Date()
    // v2 (§4.4): deterministik kural + semantik eşik. `matches()` bunları kullanır.
    var rule: String?                    // "topic:ai AND type:note AND after:2026-01"
    var threshold: Double?               // semantik üyelik için merkezlenmiş cosine eşiği
    static let databaseTableName = "space"
}

/// Space üyeliği MATERYALIZE (v2 §4.4). Üç kaynak: manual|rule|semantic.
struct ItemSpace: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var spaceId: String
    var source: String = "manual"        // manual|rule|semantic
    var excluded: Bool = false           // "bu buraya ait değil" kalıcı kararı
    static let databaseTableName = "item_space"
}

struct MetaField: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var itemId: String
    var key: String
    var value: String
    static let databaseTableName = "meta_field"
}
