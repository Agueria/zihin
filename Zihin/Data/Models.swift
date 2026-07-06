import Foundation
import GRDB

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
    static let databaseTableName = "space"
}

struct ItemSpace: Codable, Sendable, FetchableRecord, PersistableRecord {
    var itemId: String
    var spaceId: String
    static let databaseTableName = "item_space"
}

struct MetaField: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var itemId: String
    var key: String
    var value: String
    static let databaseTableName = "meta_field"
}
