# ZIHIN — Eksiksiz Development Sheet (Swift / iOS)
### "mymind, ama arka planda LLM API yok" — on-device ML + CloudKit, sıfır marjinal maliyet

> Codename **ZIHIN** (rename serbest). Bu doküman **tek başına yeterli** olacak şekilde yazıldı: ürün, mimari, Xcode kurulumu, klasör yapısı, data layer, ML/enrichment, capture, Instagram/social ingestion, video pipeline, hybrid search, CloudKit sync, SwiftUI UI, E1–E5 eklentileri, izinler, build/ship. Engine/data/ingestion/search/sync katmanları **tam kod**; UI katmanı temsili tam örnekler + her view için net spec.

---

## 0. Bu dokümanı nasıl kullanırsın

1. **Bölüm 3**'le başla (Xcode kurulumu) → proje + Share Extension + capabilities ayağa kalksın.
2. **Bölüm 4**'teki klasör yapısını birebir oluştur.
3. Katmanları **şu sırayla** kodla: Data (5) → ML/Enrichment (6) → Capture (7) → Search (10) → UI (12). Link/Video/Sync/Eklentiler sonra.
4. Her servisin kodu kopyala-yapıştır çalışacak şekilde yazıldı; `import`'lar her dosyanın başında.
5. **Derleme stratejisi:** her servisi yazdıkça derle. iOS/Xcode sürümüne göre yalnızca *availability* bayraklarını (ör. on-device speech desteği) cihazda doğrula — kod buna karşı guard'lı yazıldı.

**Min hedef:** iOS 17.0, Xcode 16, Swift 6 (concurrency strict). Cihazda test et (Simulator'da Vision/Speech sınırlı).

---

## 1. Ürün & Scope (final)

**Tek cümle:** Tek tap'le not/görsel/link/video/PDF kaydet; uygulama cihazda ne olduğunu anlar, OCR'lar, etiketler, embed eder, aranabilir yapar. Klasör yok.

**İçerik tipleri:** `note`, `quote`, `link`, `image`, `pdf`, `video`.

**Çekirdek yetenekler:**
- Capture: Share Extension (Safari/Photos/Instagram/herhangi bir app) + uygulama içi.
- Enrichment (hepsi on-device): OCR, image classification, image feature print (Same Vibe), renk paleti, NER, keyword, extractive summary, sentence embedding.
- **Social/rich link ingestion (Instagram dahil):** OG/oEmbed → caption + poster frame → image pipeline; mümkünse video indir → video pipeline.
- **Video pipeline:** frame sampling + per-frame OCR/classify + on-device speech-to-text → aranabilir transcript.
- Search: hybrid (FTS5 keyword + vektör semantic + renk/tarih filtre) + Same Vibe.
- Recall: Timeline, Smart Spaces, Serendipity (keep/forget), Top of mind (pin).
- Sync: CloudKit private DB (Phase 3, additive). Offline-first.
- **Eklentiler E1–E5** (hepsi bu sheet'te): Obsidian export, knowledge graph, E2E encryption, rich content-type cards, opsiyonel on-device LLM.

**Kapsam dışı:** sosyal paylaşım/collab, long-form editör, cloud LLM chat.

---

## 2. Mimari Genel Bakış

```
┌──────────────────────────── iOS App (SwiftUI) ────────────────────────────┐
│  Share Extension ─┐                                                        │
│  In-app capture ──┴──► IngestionService (orchestrator)                     │
│                              │                                             │
│        ┌─────────────────────┼─────────────────────────────┐              │
│        ▼                     ▼                              ▼              │
│  VisionService        LanguageService                 LinkMetadata /       │
│  (OCR/classify/        (embed/NER/lang)               VideoEnrichment      │
│   featureprint)       SummaryService                  (frames + STT)       │
│  ColorService         KeywordService                                       │
│        └─────────────────────┬─────────────────────────────┘              │
│                              ▼                                             │
│                    DatabaseManager (GRDB)                                  │
│        SQLite + FTS5 (keyword) + vector BLOB (semantic) + SQLCipher (E3)   │
│                              │                                             │
│        ┌─────────────────────┼─────────────────────────────┐              │
│        ▼                     ▼                              ▼              │
│   SearchService         UI (Timeline/Detail/         CloudKitSyncService  │
│   (FTS5 + cosine        Search/Spaces/Serendipity)   (Phase 3, $0)        │
│    + RRF fusion)                                                           │
└───────────────────────────────────────────────────────────────────────────┘
        DB dosyası App Group container'da → app + extension ortak erişim.
        ML asla buluta gitmez. CloudKit yalnızca veriyi taşır, inference yapmaz.
```

**Sürdürülebilirlik:** inference cihazda ($0), sync CloudKit private DB (kullanıcının iCloud kotası, sana $0), storage/search lokal ($0). Kullanıcı başına marjinal maliyet ≈ $0. Sabit gider yalnız Apple Developer $99/yıl.

---

## 3. Xcode Proje Kurulumu (adım adım)

### 3.1 Proje oluştur
1. Xcode → **New Project → iOS → App**.
2. Name: `Zihin`. Interface: **SwiftUI**. Language: **Swift**. Storage: **None** (GRDB kullanacağız). Min deployment: **iOS 17.0**.
3. Bundle ID: `app.zihin.Zihin` (kendine göre).

### 3.2 Share Extension target ekle
1. **File → New → Target → Share Extension**. Name: `ShareExtension`.
2. "Activate scheme" → Yes.
3. Bu target paylaşılan veriyi yakalayıp ortak DB'ye yazacak.

### 3.3 App Group (app ↔ extension ortak depolama)
1. Her iki target için **Signing & Capabilities → + Capability → App Groups**.
2. Grup ekle: `group.app.zihin`. **İki target'ta da aynı grup işaretli olmalı.**
3. GRDB veritabanı dosyası bu App Group container'ında yaşayacak (Bölüm 5.2).

### 3.4 iCloud / CloudKit (Phase 3)
1. Ana app target → **+ Capability → iCloud** → **CloudKit** işaretle.
2. Container: `iCloud.app.zihin`.
3. (Sync'i sonra yazacağız; şimdi sadece capability açık olsun.)

### 3.5 Background (opsiyonel, sync için)
- Ana app → **+ Capability → Background Modes → Background fetch / Remote notifications** (CloudKit push için ileride).

### 3.6 Swift Package dependencies
**File → Add Package Dependencies**, şunları ekle (ana app + gereken yerlerde extension target'a da):

| Paket | URL | Ne için |
|---|---|---|
| **GRDB.swift** | `https://github.com/groue/GRDB.swift` | SQLite + FTS5 + SQLCipher. **GRDB-with-SQLCipher** ürününü seç (E3 için). |
| **SwiftSoup** | `https://github.com/scinfu/SwiftSoup` | HTML/OG meta parsing |

> MobileCLIP / MLX (E5) opsiyonel — Bölüm 13'te. Başta gerekmez.

### 3.7 Info.plist izin metinleri (ana app)
`Info` sekmesine ekle:

| Key | Değer (örnek) |
|---|---|
| `NSPhotoLibraryUsageDescription` | "Kaydettiğin görselleri ve videoları içe aktarmak için." |
| `NSSpeechRecognitionUsageDescription` | "Videolardaki konuşmayı cihazında metne çevirip aranabilir yapmak için." |
| `NSMicrophoneUsageDescription` | "Sesli not ve ekran kaydı içeriğini işlemek için." |
| `NSCameraUsageDescription` | "Doğrudan fotoğraf/tarama eklemek için." (kamera kullanırsan) |

> **ATS:** Default kalsın (HTTPS zorunlu). Link fetch'leri HTTPS. Gerekmedikçe `NSAllowsArbitraryLoads` AÇMA.

### 3.8 Concurrency
- Build Settings → **Swift Concurrency → Strict Concurrency Checking = Complete** (Swift 6). Servisler `Sendable`/actor uyumlu yazıldı.

---

## 4. Proje Klasör Yapısı

Ana app target altında bu yapıyı oluştur (gruplar = klasörler):

```
Zihin/
├── App/
│   ├── ZihinApp.swift               // @main, DI/container kurulumu
│   └── AppEnvironment.swift         // paylaşılan servis konteyneri
├── Data/
│   ├── DatabaseManager.swift        // GRDB kurulumu, migrations, App Group path
│   ├── Models/
│   │   ├── Item.swift               // ana kayıt + GRDB conformance
│   │   ├── Tag.swift
│   │   ├── ItemTag.swift
│   │   ├── Space.swift
│   │   └── MetaField.swift
│   ├── ItemRepository.swift         // CRUD + sorgular
│   └── VectorStore.swift            // embedding BLOB <-> [Float], cosine
├── ML/
│   ├── VisionService.swift          // OCR, classify, featureprint, saliency
│   ├── LanguageService.swift        // NER, dil tespiti
│   ├── EmbeddingService.swift       // NLEmbedding + Core ML multilingual
│   ├── MultilingualEmbedder.swift   // (ops.) Core ML sentence model
│   ├── ColorService.swift           // k-means palet + isimli renk
│   ├── SummaryService.swift         // TextRank extractive
│   └── KeywordService.swift         // RAKE/YAKE-benzeri + stopwords
├── Capture/
│   ├── IngestionService.swift       // pipeline orchestrator
│   ├── ContentTypeDetector.swift    // tip tespiti
│   ├── LinkMetadataService.swift    // OG/oEmbed fetch + parse
│   ├── SocialIngestor.swift         // Instagram/TikTok/YouTube/X özel
│   └── VideoEnrichmentService.swift // frame sampling + STT
├── Search/
│   ├── SearchService.swift          // hybrid FTS5 + vector + RRF
│   └── SearchQueryParser.swift      // renk/tarih sinyali ayıklama
├── Sync/
│   └── CloudKitSyncService.swift    // GRDB <-> CKRecord (Phase 3)
├── Features/                        // E1–E5
│   ├── ObsidianExporter.swift       // E1
│   ├── KnowledgeGraph.swift         // E2 (veri) + GraphView (UI)
│   ├── Crypto/Keychain.swift        // E3 anahtar yönetimi
│   ├── DomainEnricher.swift         // E4 (GitHub/YouTube/X kartları)
│   └── LocalLLM.swift               // E5 (MLX, opsiyonel, default kapalı)
├── UI/
│   ├── TimelineView.swift           // ana grid
│   ├── CardView.swift               // tip'e göre kart
│   ├── Detail/
│   │   ├── ArticleDetailView.swift  // reader (WKWebView + readerHTML)
│   │   ├── ImageDetailView.swift
│   │   ├── VideoDetailView.swift
│   │   └── NoteDetailView.swift
│   ├── SearchView.swift
│   ├── SpacesView.swift
│   ├── SerendipityView.swift
│   └── SettingsView.swift
└── Support/
    ├── Stopwords.swift              // TR + EN stopword setleri
    ├── NamedColors.swift            // isimli renk paleti (TR+EN)
    └── Extensions.swift             // CGImage/UIImage/Date yardımcıları

ShareExtension/
├── ShareViewController.swift        // gelen item'ı App Group DB'ye yazar
└── Info.plist                       // NSExtensionActivationRule
```

---

## 5. Data Layer (GRDB)

GRDB seçildi çünkü tek pakette: **FTS5 full-text + raw SQL + BLOB (vektör) + SQLCipher (E3 encryption)**. Offline-first tek kaynak.

### 5.1 Şema (kavramsal)

- `item` — ana kayıt (tip, metin, OCR, summary, embedding BLOB, feature print BLOB, renkler, tarih, pin/forget, kaynak URL, asset yolu).
- `item_fts` — FTS5 virtual table (title, text, ocr, summary) → keyword arama.
- `tag` + `item_tag` — many-to-many etiket.
- `space` — manuel veya smart (kayıtlı sorgu) space.
- `meta_field` — tip'e özel key/value (price, author, duration, transcript ...).

### 5.2 DatabaseManager.swift

```swift
import Foundation
import GRDB

/// App Group içindeki tek SQLite dosyasını yönetir (app + extension ortak).
final class DatabaseManager {
    static let shared = try! DatabaseManager()
    let dbPool: DatabasePool

    private static let appGroupID = "group.app.zihin"
    private static let dbFileName = "zihin.sqlite"

    init() throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw DBError.noAppGroup
        }
        let dbURL = container.appendingPathComponent(Self.dbFileName)

        var config = Configuration()
        config.foreignKeysEnabled = true

        // --- E3: encryption (SQLCipher) ---
        // GRDB-with-SQLCipher ürünü seçiliyse açık olur. Anahtar Keychain'de.
        #if canImport(GRDBSQLCipher) || ZIHIN_ENCRYPTED
        config.prepareDatabase { db in
            let key = try KeychainKey.databasePassphrase()   // Features/Crypto/Keychain.swift
            try db.usePassphrase(key)
        }
        #endif

        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(dbPool)
    }

    enum DBError: Error { case noAppGroup }

    // MARK: - Migrations
    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()           // UUID string
                t.column("type", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("title", .text)
                t.column("url", .text)
                t.column("textContent", .text)
                t.column("readerHTML", .text)
                t.column("summary", .text)
                t.column("ocrText", .text)
                t.column("transcript", .text)                // video STT
                t.column("frameText", .text)                 // video kare OCR birleşimi
                t.column("assetPath", .text)                 // local image/pdf/video
                t.column("posterPath", .text)                // video/link poster
                t.column("dominantColors", .text)            // JSON: ["red","blue"]
                t.column("durationSec", .double)
                t.column("siteName", .text)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("forgotten", .boolean).notNull().defaults(to: false)
                t.column("embedding", .blob)                 // [Float] LE bytes
                t.column("featurePrint", .blob)              // VNFeaturePrintObservation archive
                t.column("ckSystemFields", .blob)            // CloudKit metadata (Phase 3)
                t.column("dirty", .boolean).notNull().defaults(to: true) // sync flag
            }

            try db.create(table: "tag") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().collate(.nocase)
                t.column("source", .text).notNull()          // "auto" | "manual"
                t.uniqueKey(["name"])
            }
            try db.create(table: "item_tag") { t in
                t.column("itemId", .text).notNull()
                    .references("item", onDelete: .cascade)
                t.column("tagId", .text).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["itemId", "tagId"])
            }

            try db.create(table: "space") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("isSmart", .boolean).notNull().defaults(to: false)
                t.column("query", .text)                     // smart space arama metni
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "meta_field") { t in
                t.column("id", .text).primaryKey()
                t.column("itemId", .text).notNull()
                    .references("item", onDelete: .cascade)
                t.column("key", .text).notNull()             // "price","author","channel"...
                t.column("value", .text).notNull()
            }

            // FTS5 (keyword search). content=item ile senkron tutulur.
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.column("title")
                t.column("textContent")
                t.column("ocrText")
                t.column("summary")
                t.column("transcript")
                t.column("frameText")
                t.tokenizer = .unicode61(diacritics: .remove)  // TR/EN dostu
            }
        }
        return m
    }
}
```

> **Not (FTS5 synchronize):** `t.synchronize(withTable: "item")` GRDB'ye trigger'lar kurdurur; `item`'a insert/update/delete olduğunda `item_fts` otomatik güncellenir. Manuel index yönetimi gerekmez.

### 5.3 Item.swift (model + GRDB conformance)

```swift
import Foundation
import GRDB

enum ItemType: String, Codable, CaseIterable, Sendable {
    case note, quote, link, image, pdf, video
}

struct Item: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var type: ItemType
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
    var dominantColors: String?          // JSON encoded [String]
    var durationSec: Double?
    var siteName: String?
    var isPinned: Bool = false
    var forgotten: Bool = false
    var embedding: Data?                 // [Float] little-endian
    var featurePrint: Data?
    var ckSystemFields: Data?
    var dirty: Bool = true

    static let databaseTableName = "item"

    // Yardımcı: renk listesi
    var colors: [String] {
        get { (try? JSONDecoder().decode([String].self,
               from: Data((dominantColors ?? "[]").utf8))) ?? [] }
        set { dominantColors = String(data: (try? JSONEncoder().encode(newValue)) ?? Data(),
                                      encoding: .utf8) }
    }
}
```

### 5.4 Tag / ItemTag / Space / MetaField

```swift
import GRDB
import Foundation

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
    var query: String?
    var createdAt: Date = Date()
    static let databaseTableName = "space"
}

struct MetaField: Identifiable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String = UUID().uuidString
    var itemId: String
    var key: String
    var value: String
    static let databaseTableName = "meta_field"
}
```

### 5.5 VectorStore.swift (embedding BLOB <-> [Float], cosine)

```swift
import Foundation

/// Embedding'i kompakt BLOB olarak saklar ve cosine benzerliği hesaplar.
enum VectorStore {
    static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }
}
```

### 5.6 ItemRepository.swift (CRUD + sorgular)

```swift
import Foundation
import GRDB

struct ItemRepository {
    let db = DatabaseManager.shared.dbPool

    // MARK: Yazma
    func save(_ item: inout Item) throws {
        var it = item; it.updatedAt = Date(); it.dirty = true
        try db.write { d in try it.save(d) }
        item = it
    }

    func attachTags(_ names: [String], to itemId: String, source: String = "auto") throws {
        try db.write { d in
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                // upsert tag
                var tag = try Tag.filter(Column("name") == name).fetchOne(d)
                    ?? Tag(name: name, source: source)
                try tag.save(d)
                try ItemTag(itemId: itemId, tagId: tag.id).insert(d, onConflict: .ignore)
            }
        }
    }

    func setMeta(_ pairs: [String: String], itemId: String) throws {
        try db.write { d in
            for (k, v) in pairs {
                try MetaField(itemId: itemId, key: k, value: v).insert(d)
            }
        }
    }

    // MARK: Okuma
    func timeline(includeForgotten: Bool = false) throws -> [Item] {
        try db.read { d in
            var q = Item.order(Column("isPinned").desc, Column("createdAt").desc)
            if !includeForgotten { q = q.filter(Column("forgotten") == false) }
            return try q.fetchAll(d)
        }
    }

    func item(id: String) throws -> Item? {
        try db.read { try Item.fetchOne($0, key: id) }
    }

    func allEmbeddings() throws -> [(id: String, vec: [Float])] {
        try db.read { d in
            let rows = try Item
                .filter(Column("embedding") != nil && Column("forgotten") == false)
                .fetchAll(d)
            return rows.compactMap { it in
                guard let e = it.embedding else { return nil }
                return (it.id, VectorStore.decode(e))
            }
        }
    }

    func allFeaturePrints(excluding id: String) throws -> [(id: String, fp: Data)] {
        try db.read { d in
            try Item
                .filter(Column("featurePrint") != nil && Column("id") != id)
                .fetchAll(d)
                .compactMap { it in it.featurePrint.map { (it.id, $0) } }
        }
    }

    func setPinned(_ pinned: Bool, id: String) throws {
        try db.write { d in
            try Item.filter(key: id).updateAll(d,
                Column("isPinned").set(to: pinned),
                Column("updatedAt").set(to: Date()),
                Column("dirty").set(to: true))
        }
    }

    func setForgotten(_ forgotten: Bool, id: String) throws {
        try db.write { d in
            try Item.filter(key: id).updateAll(d,
                Column("forgotten").set(to: forgotten),
                Column("updatedAt").set(to: Date()),
                Column("dirty").set(to: true))
        }
    }
}
```

> Bu noktada veri katmanı tamamen çalışır: kayıt ekle/güncelle/sil, etiket, meta, timeline, embedding/feature print toplu çek. Sonraki katman bu kayıtları **doldurur** (enrichment).

---

## 6. ML / Enrichment Layer (hepsi on-device, $0)

### 6.1 VisionService.swift — OCR, classification, feature print

```swift
import Vision
import CoreGraphics
import UIKit

struct VisionResult: Sendable {
    var ocrText: String
    var classifications: [String]   // güvenilir etiketler
    var featurePrint: Data?         // VNFeaturePrintObservation (archived)
}

enum VisionService {
    /// Tek görseli OCR + classify + feature print ile işler.
    static func analyze(cgImage: CGImage,
                        languages: [String] = ["tr-TR", "en-US"]) -> VisionResult {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        textReq.recognitionLanguages = languages

        let classReq = VNClassifyImageRequest()
        let fpReq = VNGenerateImageFeaturePrintRequest()

        var ocr = ""; var classes: [String] = []; var fpData: Data?
        do {
            try handler.perform([textReq, classReq, fpReq])
        } catch {
            return VisionResult(ocrText: "", classifications: [], featurePrint: nil)
        }

        if let obs = textReq.results {
            ocr = obs.compactMap { $0.topCandidates(1).first?.string }
                     .joined(separator: "\n")
        }
        if let obs = classReq.results {
            classes = obs.filter { $0.hasMinimumRecall(0.0, forPrecision: 0.0) && $0.confidence > 0.2 }
                         .prefix(8)
                         .map { $0.identifier }
        }
        if let obs = fpReq.results?.first {
            fpData = try? NSKeyedArchiver.archivedData(withRootObject: obs,
                                                       requiringSecureCoding: true)
        }
        return VisionResult(ocrText: ocr, classifications: classes, featurePrint: fpData)
    }

    /// İki feature print arası mesafe (küçük = benzer). Same Vibe + dedup.
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard
            let oa = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: a),
            let ob = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: b)
        else { return nil }
        var dist: Float = 0
        do { try oa.computeDistance(&dist, to: ob); return dist } catch { return nil }
    }
}
```

> Not: `VNClassifyImageRequest` Apple'ın yerleşik ~1000+ sınıf taksonomisini kullanır; ekstra model gerekmez. `confidence > 0.2` eşiğini test ederek ayarla.

### 6.2 LanguageService.swift — dil tespiti + NER

```swift
import NaturalLanguage

enum LanguageService {
    static func dominantLanguage(_ text: String) -> NLLanguage? {
        guard !text.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage
    }

    /// Kişi / yer / organizasyon adlarını çıkarır (brand etiketleme).
    static func namedEntities(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType, options: opts) { tag, range in
            if let tag, wanted.contains(tag) {
                out.append(String(text[range]))
            }
            return true
        }
        return Array(Set(out))
    }
}
```

### 6.3 EmbeddingService.swift + MultilingualEmbedder.swift

İngilizce için Apple'ın yerleşik sentence embedding'i bedava. **Türkçe içerik** için bundled bir Core ML multilingual modeli öneriyoruz (yoksa EN'e düşer).

```swift
import NaturalLanguage

enum EmbeddingService {
    private static let enSentence = NLEmbedding.sentenceEmbedding(for: .english)

    /// Metni vektöre çevirir. Multilingual Core ML modeli yüklüyse onu, değilse Apple EN'i kullanır.
    static func embed(_ text: String) -> [Float]? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        if let v = MultilingualEmbedder.shared?.vector(for: clean) {
            return v
        }
        if let d = enSentence?.vector(for: clean) {
            return d.map { Float($0) }   // [Double] -> [Float]
        }
        return nil
    }
}
```

```swift
import CoreML
import NaturalLanguage

/// (Opsiyonel ama TR için önerilir) Bundle edilmiş sentence-transformers Core ML modeli.
/// Model: paraphrase-multilingual-MiniLM-L12-v2 (384-dim), coremltools ile dönüştürülür.
/// Yoksa shared = nil olur ve EmbeddingService Apple EN'e düşer.
final class MultilingualEmbedder {
    static let shared: MultilingualEmbedder? = try? MultilingualEmbedder()

    // Buraya dönüştürdüğün modelin generated class'ı gelir (ör. MiniLMEmbedder).
    // private let model: MiniLMEmbedder

    init() throws {
        // self.model = try MiniLMEmbedder(configuration: MLModelConfiguration())
        throw NSError(domain: "Zihin", code: -1)  // model eklenene kadar nil döner
    }

    func vector(for text: String) -> [Float]? {
        // 1) Tokenize (WordPiece) -> input_ids/attention_mask
        // 2) model.prediction(...) -> last_hidden_state
        // 3) mean pooling (attention mask ile) -> 384-dim
        // 4) L2 normalize
        return nil  // model eklendiğinde gerçek implementasyon
    }
}
```

**Modeli üretme reçetesi (bir kez, Mac'te):**
```bash
pip install coremltools transformers torch sentence-transformers
```
```python
# convert_embedder.py
import torch, coremltools as ct
from transformers import AutoModel, AutoTokenizer
name = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
tok = AutoTokenizer.from_pretrained(name)
model = AutoModel.from_pretrained(name).eval()
ex = tok("örnek cümle", return_tensors="pt", padding="max_length", max_length=128, truncation=True)
traced = torch.jit.trace(model, (ex["input_ids"], ex["attention_mask"]))
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=ex["input_ids"].shape, dtype=int),
            ct.TensorType(name="attention_mask", shape=ex["attention_mask"].shape, dtype=int)],
    minimum_deployment_target=ct.target.iOS17)
mlmodel.save("MiniLMEmbedder.mlpackage")
# .mlpackage'ı Xcode'a sürükle; mean-pooling'i Swift tarafında yap (yukarıdaki vector()).
```

> MVP'de modeli ekleMEden başlayabilirsin (EN embedding ile). TR arama kalitesi düşükse modeli ekle. Mimari değişmez.

### 6.4 ColorService.swift — k-means palet + isimli renk (saf algoritma)

```swift
import UIKit
import CoreGraphics

enum ColorService {
    /// Görselden baskın renkleri çıkarır ve en yakın isimli renklere map'ler.
    static func dominantColorNames(cgImage: CGImage, k: Int = 5) -> [String] {
        let pixels = samplePixels(cgImage, maxDim: 64)
        guard !pixels.isEmpty else { return [] }
        let centers = kMeans(pixels, k: min(k, pixels.count), iterations: 8)
        let names = centers.map { NamedColors.nearest(to: $0) }
        // tekille, sıralı
        var seen = Set<String>(); var out: [String] = []
        for n in names where !seen.contains(n) { seen.insert(n); out.append(n) }
        return out
    }

    private struct RGB { var r: Float; var g: Float; var b: Float }

    private static func samplePixels(_ img: CGImage, maxDim: Int) -> [RGB] {
        let scale = Float(maxDim) / Float(max(img.width, img.height))
        let w = max(1, Int(Float(img.width) * scale))
        let h = max(1, Int(Float(img.height) * scale))
        var data = [UInt8](repeating: 0, count: w*h*4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w*4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [RGB] = []; out.reserveCapacity(w*h)
        var i = 0
        while i < data.count {
            out.append(RGB(r: Float(data[i]), g: Float(data[i+1]), b: Float(data[i+2])))
            i += 4
        }
        return out
    }

    private static func kMeans(_ pts: [RGB], k: Int, iterations: Int) -> [RGB] {
        var centers = (0..<k).map { pts[$0 * pts.count / k] }
        for _ in 0..<iterations {
            var sums = Array(repeating: RGB(r:0,g:0,b:0), count: k)
            var counts = Array(repeating: 0, count: k)
            for p in pts {
                var best = 0; var bestD = Float.greatestFiniteMagnitude
                for (j, c) in centers.enumerated() {
                    let d = (p.r-c.r)*(p.r-c.r)+(p.g-c.g)*(p.g-c.g)+(p.b-c.b)*(p.b-c.b)
                    if d < bestD { bestD = d; best = j }
                }
                sums[best].r += p.r; sums[best].g += p.g; sums[best].b += p.b
                counts[best] += 1
            }
            for j in 0..<k where counts[j] > 0 {
                centers[j] = RGB(r: sums[j].r/Float(counts[j]),
                                 g: sums[j].g/Float(counts[j]),
                                 b: sums[j].b/Float(counts[j]))
            }
        }
        return centers
    }

    static func rgb(_ img: CGImage) -> (Float,Float,Float)? { nil } // (kullanılmıyor; ileride)
}
```

### 6.5 SummaryService.swift — TextRank extractive (LLM yok)

```swift
import NaturalLanguage

enum SummaryService {
    /// En önemli `n` cümleyi (orijinal sırada) seçer.
    static func summarize(_ text: String, n: Int = 3) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > n else { return sentences.joined(separator: " ") }

        // 1) Cümle vektörleri (embedding varsa onunla, yoksa kelime TF cosine)
        let vecs: [[Float]] = sentences.map { EmbeddingService.embed($0) ?? [] }
        let usable = vecs.allSatisfy { !$0.isEmpty }

        // 2) Benzerlik matrisi
        let n0 = sentences.count
        var sim = Array(repeating: Array(repeating: Float(0), count: n0), count: n0)
        for i in 0..<n0 {
            for j in (i+1)..<n0 {
                let s = usable ? VectorStore.cosine(vecs[i], vecs[j])
                               : tfCosine(sentences[i], sentences[j])
                sim[i][j] = s; sim[j][i] = s
            }
        }
        // 3) PageRank (power iteration)
        var rank = Array(repeating: Float(1)/Float(n0), count: n0)
        let damping: Float = 0.85
        for _ in 0..<30 {
            var next = Array(repeating: (1-damping)/Float(n0), count: n0)
            for i in 0..<n0 {
                let outSum = sim[i].reduce(0,+)
                guard outSum > 0 else { continue }
                for j in 0..<n0 where i != j {
                    next[j] += damping * rank[i] * (sim[i][j] / outSum)
                }
            }
            rank = next
        }
        // 4) En yüksek n cümle, orijinal sırada
        let top = rank.enumerated().sorted { $0.element > $1.element }.prefix(n)
                      .map { $0.offset }.sorted()
        return top.map { sentences[$0] }.joined(separator: " ")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 1 { out.append(s) }
            return true
        }
        return out
    }

    private static func tfCosine(_ a: String, _ b: String) -> Float {
        func bag(_ s: String) -> [String:Float] {
            var d: [String:Float] = [:]
            for w in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
                let t = String(w); if Stopwords.all.contains(t) { continue }
                d[t, default: 0] += 1
            }
            return d
        }
        let x = bag(a), y = bag(b)
        let keys = Set(x.keys).union(y.keys)
        var dot: Float = 0, nx: Float = 0, ny: Float = 0
        for k in keys { let vx = x[k] ?? 0, vy = y[k] ?? 0; dot += vx*vy; nx += vx*vx; ny += vy*vy }
        let den = nx.squareRoot()*ny.squareRoot()
        return den == 0 ? 0 : dot/den
    }
}
```

### 6.6 KeywordService.swift — RAKE-benzeri otomatik etiket

```swift
import Foundation

enum KeywordService {
    /// Stopword'lere göre aday ifadeler üretir, deg/freq ile skorlar, en iyi `n`'i döndürür.
    static func keywords(_ text: String, n: Int = 8) -> [String] {
        let lower = text.lowercased()
        // 1) Stopword ve noktalama ile böl -> aday ifadeler
        var phrases: [[String]] = []
        var current: [String] = []
        for token in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(token)
            if Stopwords.all.contains(t) || t.count < 2 {
                if !current.isEmpty { phrases.append(current); current = [] }
            } else {
                current.append(t)
            }
        }
        if !current.isEmpty { phrases.append(current) }

        // 2) Kelime skorları: degree / frequency
        var freq: [String:Int] = [:], degree: [String:Int] = [:]
        for p in phrases {
            let deg = p.count - 1
            for w in p { freq[w, default: 0] += 1; degree[w, default: 0] += deg }
        }
        var wordScore: [String:Float] = [:]
        for w in freq.keys {
            wordScore[w] = Float(degree[w]! + freq[w]!) / Float(freq[w]!)
        }
        // 3) İfade skoru = kelime skorları toplamı
        var phraseScore: [(String,Float)] = phrases.map { p in
            (p.joined(separator: " "), p.reduce(Float(0)) { $0 + (wordScore[$1] ?? 0) })
        }
        // 4) Tekille + sırala + kısalt
        var seen = Set<String>(); phraseScore = phraseScore.filter { seen.insert($0.0).inserted }
        return phraseScore.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 }
    }
}
```

**Support/Stopwords.swift** (kısa set — genişlet):
```swift
enum Stopwords {
    static let tr: Set<String> = ["ve","ile","bir","bu","da","de","için","çok","ama","gibi",
        "ki","ya","mu","mı","ne","o","şu","en","daha","sonra","önce","kadar","hem","veya","ya da"]
    static let en: Set<String> = ["the","and","a","an","of","to","in","is","it","for","on","with",
        "as","at","by","this","that","or","be","are","from","but","not","you","your","we","can"]
    static let all: Set<String> = tr.union(en)
}
```

**Support/NamedColors.swift** (isimli renk eşleme — TR+EN):
```swift
import Foundation

enum NamedColors {
    // (isim, R, G, B). Genişletebilirsin.
    static let palette: [(name: String, r: Float, g: Float, b: Float)] = [
        ("siyah", 0,0,0), ("beyaz", 255,255,255), ("gri", 128,128,128),
        ("kırmızı", 220,30,30), ("turuncu", 240,140,20), ("sarı", 240,220,40),
        ("yeşil", 40,170,70), ("mavi", 40,90,210), ("lacivert", 20,30,110),
        ("mor", 130,60,180), ("pembe", 240,120,170), ("kahverengi", 120,75,40),
        ("bej", 225,200,160), ("turkuaz", 40,190,190)
    ]
    static func nearest(to rgb: (r: Float, g: Float, b: Float)) -> String {
        var best = palette[0].name; var bestD = Float.greatestFiniteMagnitude
        for c in palette {
            let d = (rgb.r-c.r)*(rgb.r-c.r)+(rgb.g-c.g)*(rgb.g-c.g)+(rgb.b-c.b)*(rgb.b-c.b)
            if d < bestD { bestD = d; best = c.name }
        }
        return best
    }
    // ColorService bu imzayı çağırır:
    static func nearest(to rgb: ColorServiceRGB) -> String {
        nearest(to: (rgb.r, rgb.g, rgb.b))
    }
}
// ColorService.RGB private olduğundan köprü tip:
struct ColorServiceRGB { var r: Float; var g: Float; var b: Float }
```

> Pratik düzeltme: `ColorService.kMeans` çıktısını `NamedColors.nearest(to: (c.r,c.g,c.b))` ile çağır (tuple imzası). Yukarıdaki köprü tip yalnızca derleme kolaylığı; istersen `ColorService` içindeki `RGB`'yi `internal` yapıp doğrudan kullan.

---

## 7. Capture Layer

### 7.1 ContentTypeDetector.swift

```swift
import Foundation
import UniformTypeIdentifiers

enum DetectedContent: Sendable {
    case url(URL)
    case image(Data)
    case video(URL)
    case pdf(URL)
    case text(String)
}

enum ContentTypeDetector {
    /// Share Extension'dan gelen NSItemProvider'lardan içerik tipini çıkarır.
    /// (Gerçek çıkarım ShareViewController'da yapılır; burası saf sınıflandırma yardımcıları.)
    static func isWebURL(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }
}
```

### 7.2 IngestionService.swift — pipeline orchestrator (ÇEKİRDEK)

Bu servis tüm enrichment'ı tipe göre çağırır, `Item`'ı doldurur, DB'ye yazar.

```swift
import Foundation
import UIKit

actor IngestionService {
    static let shared = IngestionService()
    private let repo = ItemRepository()

    /// Tek giriş noktası. Tüm capture yolları buraya gelir.
    @discardableResult
    func ingest(_ content: DetectedContent) async -> Item {
        switch content {
        case .text(let s):        return await ingestText(s)
        case .image(let data):    return await ingestImage(data)
        case .url(let url):       return await ingestLink(url)
        case .video(let url):     return await ingestVideo(url, poster: nil, source: nil)
        case .pdf(let url):       return await ingestPDF(url)
        }
    }

    // MARK: Not / Quote
    private func ingestText(_ text: String, type: ItemType = .note) async -> Item {
        var item = Item(type: type, textContent: text)
        item.title = String(text.prefix(80))
        item.summary = SummaryService.summarize(text, n: 2)
        item.embedding = EmbeddingService.embed(text).map(VectorStore.encode)
        let tags = LanguageService.namedEntities(text) + KeywordService.keywords(text)
        await persist(&item, tags: tags)
        return item
    }

    // MARK: Image
    private func ingestImage(_ data: Data, posterFor: Item? = nil) async -> Item {
        var item = Item(type: .image)
        let path = AssetStore.save(data, ext: "jpg")
        item.assetPath = path
        if let cg = UIImage(data: data)?.cgImage {
            let v = VisionService.analyze(cgImage: cg)
            item.ocrText = v.ocrText
            item.featurePrint = v.featurePrint
            item.colors = ColorService.dominantColorNames(cgImage: cg)
            let textForEmbed = [v.ocrText, v.classifications.joined(separator: " ")]
                .joined(separator: " ")
            item.embedding = EmbeddingService.embed(textForEmbed).map(VectorStore.encode)
            let tags = v.classifications + item.colors
                + LanguageService.namedEntities(v.ocrText)
            await persist(&item, tags: tags)
        } else {
            await persist(&item, tags: [])
        }
        return item
    }

    // MARK: Link (makale + OG; social ise SocialIngestor)
    private func ingestLink(_ url: URL) async -> Item {
        // Social platform mı? (Instagram/TikTok/YouTube/X) -> özel akış
        if let social = await SocialIngestor.ingest(url: url) { return social }

        var item = Item(type: .link, url: url.absoluteString)
        do {
            let meta = try await LinkMetadataService.fetch(url)
            item.title = meta.title
            item.siteName = meta.siteName
            // Reader mode (temiz makale)
            if let html = meta.rawHTML {
                let reader = ReadabilityService.extract(html: html, baseURL: url)
                item.readerHTML = reader.contentHTML
                item.textContent = reader.text
                item.summary = SummaryService.summarize(reader.text, n: 3)
            }
            // Poster/thumbnail görselini de işle (OCR/etiket/feature print)
            if let imgURL = meta.imageURL,
               let (idata, _) = try? await URLSession.shared.data(from: imgURL),
               let cg = UIImage(data: idata)?.cgImage {
                item.posterPath = AssetStore.save(idata, ext: "jpg")
                let v = VisionService.analyze(cgImage: cg)
                item.ocrText = v.ocrText
                item.featurePrint = v.featurePrint
                item.colors = ColorService.dominantColorNames(cgImage: cg)
            }
            // Embedding: başlık + açıklama + makale metni
            let base = [meta.title, meta.description, item.textContent]
                .compactMap { $0 }.joined(separator: " ")
            item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)

            // E4: domain'e özel zenginleştirme (GitHub/YouTube/X kartları)
            let extraMeta = await DomainEnricher.enrich(url: url, base: meta)
            let tags = LanguageService.namedEntities(base)
                + KeywordService.keywords(base) + item.colors
            await persist(&item, tags: tags, meta: extraMeta)
        } catch {
            // Fetch başarısızsa en azından URL kartı
            item.title = url.host
            await persist(&item, tags: [])
        }
        return item
    }

    // MARK: Video (frame OCR + STT)
    func ingestVideo(_ url: URL, poster: Data?, source: URL?) async -> Item {
        var item = Item(type: .video, url: source?.absoluteString)
        let localPath = AssetStore.copy(fileURL: url, ext: url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
        item.assetPath = localPath

        let result = await VideoEnrichmentService.enrich(url: url)
        item.frameText = result.frameText
        item.transcript = result.transcript
        item.durationSec = result.durationSec
        item.colors = result.colors
        item.featurePrint = result.representativeFeaturePrint
        if let p = poster { item.posterPath = AssetStore.save(p, ext: "jpg") }
        else if let pf = result.posterData { item.posterPath = AssetStore.save(pf, ext: "jpg") }

        let base = [result.transcript, result.frameText].joined(separator: " ")
        item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)
        let tags = result.classifications + result.colors
            + LanguageService.namedEntities(base) + KeywordService.keywords(base)
        await persist(&item, tags: tags)
        return item
    }

    // MARK: PDF
    private func ingestPDF(_ url: URL) async -> Item {
        var item = Item(type: .pdf, url: url.absoluteString)
        let localPath = AssetStore.copy(fileURL: url, ext: "pdf")
        item.assetPath = localPath
        let text = PDFTextExtractor.extract(url: url)   // PDFKit ile (Bölüm 9 sonu)
        item.textContent = text
        item.title = url.deletingPathExtension().lastPathComponent
        item.summary = SummaryService.summarize(text, n: 3)
        item.embedding = EmbeddingService.embed(text).map(VectorStore.encode)
        let tags = LanguageService.namedEntities(text) + KeywordService.keywords(text)
        await persist(&item, tags: tags)
        return item
    }

    // MARK: ortak yazma
    private func persist(_ item: inout Item, tags: [String], meta: [String:String] = [:]) async {
        do {
            var it = item
            try repo.save(&it)
            try repo.attachTags(Array(Set(tags)), to: it.id)
            if !meta.isEmpty { try repo.setMeta(meta, itemId: it.id) }
            item = it
        } catch {
            print("Ingestion persist error: \(error)")
        }
    }
}
```

### 7.3 AssetStore.swift (görsel/video/pdf yerel saklama — App Group)

```swift
import Foundation

enum AssetStore {
    private static let appGroupID = "group.app.zihin"
    private static var dir: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!
            .appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func save(_ data: Data, ext: String) -> String {
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? data.write(to: url)
        return url.lastPathComponent      // relative; okurken dir + name
    }
    static func copy(fileURL: URL, ext: String) -> String {
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? FileManager.default.copyItem(at: fileURL, to: dest)
        return dest.lastPathComponent
    }
    static func url(for relative: String) -> URL { dir.appendingPathComponent(relative) }
}
```

### 7.4 ShareExtension/ShareViewController.swift (gelen içeriği yakala → ortak DB)

```swift
import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleShare()
    }

    private func handleShare() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else { return complete() }

        let group = DispatchGroup()
        var detected: DetectedContent?

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { obj, _ in
                    if let u = obj as? URL { detected = .url(u) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    if let url { detected = .video(url) }   // dosya kopyalanmalı (aşağıda)
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { detected = .image(data) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    if let url { detected = .pdf(url) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { obj, _ in
                    if let s = obj as? String { detected = .text(s) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            guard let detected else { return self.complete() }
            Task {
                await IngestionService.shared.ingest(detected)
                self.complete()
            }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
```

> **Kritik:** Video/PDF için `loadFileRepresentation` geçici bir URL verir; extension dönmeden **App Group container'a kopyala** (AssetStore.copy bunu yapıyor; IngestionService içinde kopyalanıyor). Aksi halde dosya silinir.

**ShareExtension Info.plist — NSExtensionActivationRule** (hangi içerik tiplerini kabul eder):
```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionAttributes</key>
  <dict>
    <key>NSExtensionActivationRule</key>
    <dict>
      <key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer>
      <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>10</integer>
      <key>NSExtensionActivationSupportsMovieWithMaxCount</key><integer>1</integer>
      <key>NSExtensionActivationSupportsText</key><true/>
      <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>5</integer>
    </dict>
  </dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.share-services</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
</dict>
```

---

## 8. Social / Rich Link Ingestion (Instagram dahil)

> **Doğru beklenti:** Bir Instagram linkini paylaştığında platform sana videoyu vermez; sen linkten **OG metadata** çekersin. Reels'te asıl içerik sinyali = (a) poster/thumbnail karesindeki **gömülü yazı (OCR)** ve (b) **caption metni**. Bunları işleyince kayıt "video içeriğine göre" aranabilir/filtrelenebilir olur — mymind'ın yaptığı da budur. Public video URL'i ele geçirilebiliyorsa, fırsatçı olarak indirip **tam video pipeline** (frame + STT) çalıştırırız.

### 8.1 LinkMetadataService.swift — OG/oEmbed fetch + parse

```swift
import Foundation
import SwiftSoup

struct LinkMetadata: Sendable {
    var title: String?
    var description: String?
    var imageURL: URL?
    var videoURL: URL?
    var siteName: String?
    var type: String?
    var price: String?
    var rawHTML: String?
}

enum LinkMetadataService {
    static func fetch(_ url: URL) async throws -> LinkMetadata {
        var req = URLRequest(url: url)
        // Crawler-benzeri UA: birçok site (Instagram dahil) crawler'a OG meta servis eder.
        req.setValue("Mozilla/5.0 (compatible; ZihinBot/1.0; +https://zihin.app/bot)",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else {
            return LinkMetadata()
        }
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        func meta(_ property: String) -> String? {
            (try? doc.select("meta[property=\(property)]").first()?.attr("content"))?
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        func metaName(_ name: String) -> String? {
            (try? doc.select("meta[name=\(name)]").first()?.attr("content"))?
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        var m = LinkMetadata()
        m.title = meta("og:title") ?? (try? doc.title())
        m.description = meta("og:description") ?? metaName("description")
        m.siteName = meta("og:site_name") ?? url.host
        m.type = meta("og:type")
        m.price = meta("product:price:amount") ?? meta("og:price:amount")
        if let s = meta("og:image"), let u = URL(string: s) { m.imageURL = u }
        if let s = meta("og:video:secure_url") ?? meta("og:video:url") ?? meta("og:video"),
           let u = URL(string: s) { m.videoURL = u }
        m.rawHTML = html
        return m
    }

    /// Bir uzak görsel/video'yu geçici dosyaya indirir.
    static func download(_ url: URL, ext: String) async -> URL? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (compatible; ZihinBot/1.0)", forHTTPHeaderField: "User-Agent")
        guard let (tmp, _) = try? await URLSession.shared.download(for: req) else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
```

### 8.2 ReadabilityService.swift — reader mode (temiz makale)

İki seçenek: (A) hafif SwiftSoup heuristiği (bağımlılık yok, default), (B) WKWebView'a **Readability.js** inject (yüksek sadakat, JS dosyası bundle edilir). Default A:

```swift
import Foundation
import SwiftSoup

struct ReaderContent: Sendable { var contentHTML: String; var text: String }

enum ReadabilityService {
    /// Heuristik: gürültü etiketlerini at, en yoğun metin bloğunu seç.
    static func extract(html: String, baseURL: URL) -> ReaderContent {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else {
            return ReaderContent(contentHTML: "", text: "")
        }
        // Gürültüyü temizle
        let noise = ["script","style","nav","aside","footer","header","form","noscript","iframe","svg"]
        for tag in noise { try? doc.select(tag).remove() }

        // Aday konteynerler
        let candidates = (try? doc.select("article, main, [role=main], .post, .article, #content"))
        let container = (candidates?.first()) ?? doc.body()
        guard let container else { return ReaderContent(contentHTML: "", text: "") }

        let contentHTML = (try? container.outerHtml()) ?? ""
        let text = (try? container.text()) ?? ""
        return ReaderContent(contentHTML: wrapReadable(contentHTML),
                             text: text)
    }

    private static func wrapReadable(_ inner: String) -> String {
        """
        <html><head><meta name='viewport' content='width=device-width, initial-scale=1'>
        <style>
          body{font:17px/1.6 -apple-system;margin:0;padding:20px;color:#111;background:#fff;}
          @media (prefers-color-scheme: dark){body{background:#111;color:#eee;}}
          img{max-width:100%;height:auto;border-radius:10px;}
          h1,h2,h3{line-height:1.25;}
          p{margin:0 0 1em;}
        </style></head><body>\(inner)</body></html>
        """
    }
}
```

> **(B) yüksek sadakat:** `Readability.js`'i (Mozilla) projeye text resource olarak ekle; offscreen `WKWebView`'a HTML yükle → `document.documentElement.outerHTML` set et → `new Readability(document).parse()` çağır → `evaluateJavaScript` ile sonucu al. Daha temiz ama JS bundling gerektirir. Sosyal linklerde A yeterli.

### 8.3 SocialIngestor.swift — Instagram / TikTok / YouTube / X

```swift
import Foundation
import UIKit

enum SocialIngestor {
    private static let socialHosts: [String] = [
        "instagram.com", "tiktok.com", "youtube.com", "youtu.be",
        "twitter.com", "x.com", "vimeo.com", "reddit.com"
    ]

    static func isSocial(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return socialHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Sosyal link ise item'ı kendisi kurar, enrichment yapar, persist eder ve döndürür.
    /// Sosyal değilse nil (IngestionService normal link akışına düşer).
    static func ingest(url: URL) async -> Item? {
        guard isSocial(url) else { return nil }
        let repo = ItemRepository()

        let meta = (try? await LinkMetadataService.fetch(url)) ?? LinkMetadata()
        let caption = [meta.title, meta.description].compactMap { $0 }.joined(separator: " ")

        // Poster/thumbnail indir + image pipeline (gömülü yazı OCR'ı burada yakalanır)
        var posterData: Data?
        var posterOCR = ""
        var posterFP: Data?
        var posterColors: [String] = []
        if let imgURL = meta.imageURL,
           let (idata, _) = try? await URLSession.shared.data(from: imgURL),
           let cg = UIImage(data: idata)?.cgImage {
            posterData = idata
            let v = VisionService.analyze(cgImage: cg)
            posterOCR = v.ocrText
            posterFP = v.featurePrint
            posterColors = ColorService.dominantColorNames(cgImage: cg)
        }

        // (Fırsatçı) Public video URL'i alınabiliyorsa indir → tam video pipeline
        if let vURL = meta.videoURL,
           let localVideo = await LinkMetadataService.download(vURL, ext: "mp4") {
            let r = await VideoEnrichmentService.enrich(url: localVideo)
            var item = Item(type: .video, url: url.absoluteString)
            item.title = meta.title
            item.siteName = meta.siteName
            item.assetPath = AssetStore.copy(fileURL: localVideo, ext: "mp4")
            item.transcript = r.transcript
            item.frameText = [r.frameText, posterOCR].joined(separator: "\n")
            item.durationSec = r.durationSec
            item.colors = Array(Set(r.colors + posterColors))
            item.featurePrint = r.representativeFeaturePrint ?? posterFP
            if let p = posterData { item.posterPath = AssetStore.save(p, ext: "jpg") }
            item.textContent = caption
            let base = [caption, r.transcript, r.frameText, posterOCR].joined(separator: " ")
            item.summary = SummaryService.summarize(base, n: 2)
            item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)
            let tags = r.classifications + item.colors
                + LanguageService.namedEntities(base) + KeywordService.keywords(base)
            persist(&item, tags: tags, siteName: meta.siteName, repo: repo)
            return item
        }

        // Video alınamadı → poster + caption ile aranabilir LINK kartı
        var item = Item(type: .link, url: url.absoluteString)
        item.title = meta.title ?? url.host
        item.siteName = meta.siteName
        item.textContent = caption
        item.ocrText = posterOCR                 // gömülü yazı → aranabilir
        item.featurePrint = posterFP
        item.colors = posterColors
        if let p = posterData { item.posterPath = AssetStore.save(p, ext: "jpg") }
        let base = [caption, posterOCR].joined(separator: " ")
        item.summary = SummaryService.summarize(base, n: 2)
        item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)
        let tags = posterColors
            + LanguageService.namedEntities(base) + KeywordService.keywords(base)
        persist(&item, tags: tags, siteName: meta.siteName, repo: repo)
        return item
    }

    private static func persist(_ item: inout Item, tags: [String],
                                siteName: String?, repo: ItemRepository) {
        do {
            var it = item
            try repo.save(&it)
            try repo.attachTags(Array(Set(tags)), to: it.id)
            if let s = siteName { try repo.setMeta(["source": s], itemId: it.id) }
            item = it
        } catch { print("Social persist error: \(error)") }
    }
}
```

**Instagram gerçeği & fallback (UI'da kullanıcıya göster):**
- Public post → genelde `og:image` (poster) + caption gelir → kayıt poster OCR + caption ile aranabilir. ✅
- `og:video` çoğunlukla logged-out gelmez → tam frame/STT yapılamaz, poster+caption yeterli olur.
- Private/sınırlı post → fetch login duvarına çarpabilir → **fallback: ekran kaydı** (kullanıcı reel'i ekran kaydeder → Photos'a düşer → app'e paylaşır → tam video pipeline: gömülü yazı + ses). Bunu Settings'te "İpucu" olarak göster.

---

## 9. Video Pipeline + PDF

### 9.1 VideoEnrichmentService.swift — frame sampling + on-device STT

```swift
import AVFoundation
import Vision
import Speech
import UIKit

struct VideoEnrichResult: Sendable {
    var frameText: String           // karelerdeki OCR (tekilleştirilmiş)
    var transcript: String          // ses -> metin (on-device)
    var classifications: [String]   // sık geçen sınıflar
    var colors: [String]
    var durationSec: Double
    var representativeFeaturePrint: Data?
    var posterData: Data?           // ilk kare JPEG
}

enum VideoEnrichmentService {
    static func enrich(url: URL,
                       maxFrames: Int = 20,
                       locale: Locale = Locale(identifier: "tr-TR")) async -> VideoEnrichResult {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0

        // 1) Frame sampling
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1080, height: 1080)   // downscale

        let count = duration > 0 ? min(maxFrames, max(1, Int(duration))) : 1
        let step = duration > 0 ? duration / Double(count) : 0

        var frameLines = Set<String>()
        var classCount: [String: Int] = [:]
        var colorSet = Set<String>()
        var firstFrameData: Data?
        var midFeaturePrint: Data?

        for i in 0..<count {
            let t = CMTime(seconds: Double(i) * step + step/2, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }

            if i == 0 {
                firstFrameData = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
            }
            let v = VisionService.analyze(cgImage: cg)
            for line in v.ocrText.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.count > 1 { frameLines.insert(s) }
            }
            for c in v.classifications { classCount[c, default: 0] += 1 }
            if i == count/2 {
                midFeaturePrint = v.featurePrint
                colorSet.formUnion(ColorService.dominantColorNames(cgImage: cg))
            }
        }

        let topClasses = classCount.sorted { $0.value > $1.value }.prefix(8).map { $0.key }

        // 2) On-device speech-to-text
        let transcript = await transcribe(url: url, locale: locale)

        return VideoEnrichResult(
            frameText: frameLines.joined(separator: "\n"),
            transcript: transcript,
            classifications: Array(topClasses),
            colors: Array(colorSet),
            durationSec: duration,
            representativeFeaturePrint: midFeaturePrint,
            posterData: firstFrameData
        )
    }

    /// On-device speech recognition. TR on-device yoksa server-based'e düşer (yine $0 ama ses Apple'a gider).
    private static func transcribe(url: URL, locale: Locale) async -> String {
        // İzin
        let authed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        guard authed, let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else { return "" }

        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true     // privacy: cihazda kal
        }
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal, !finished {
                    finished = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil, !finished {
                    finished = true
                    c.resume(returning: result?.bestTranscription.formattedString ?? "")
                }
            }
        }
    }
}
```

> **Bellek:** `maxFrames`'i 20'de tut, `maximumSize` ile downscale et. Uzun videolarda kare başına Vision pahalı; gerekirse `maxFrames`'i süreyle ölçekle ama tavan koy. STT uzun videoda yavaştır; kullanıcıya progress göster.

### 9.2 PDFTextExtractor.swift

```swift
import PDFKit

enum PDFTextExtractor {
    static func extract(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string { out += s + "\n" }
        }
        // Taranmış (text'siz) PDF ise sayfaları görsele çevirip Vision OCR uygula (opsiyonel v1.5).
        return out
    }
}
```

---

## 10. Search Layer (hybrid)

mymind'ın "renk / keyword / brand / tarih — ne aklına gelirse" hissi = FTS5 keyword + vektör semantic + renk/tarih filtre, **Reciprocal Rank Fusion** ile birleştirilir.

### 10.1 SearchQueryParser.swift

```swift
import Foundation

struct ParsedQuery: Sendable {
    var cleaned: String
    var colors: [String]
    var dateRange: (start: Date, end: Date)?
}

enum SearchQueryParser {
    static func parse(_ query: String) -> ParsedQuery {
        var tokens = query.lowercased().split(separator: " ").map(String.init)
        let colorNames = Set(NamedColors.palette.map { $0.name })
        let colors = tokens.filter { colorNames.contains($0) }
        tokens.removeAll { colorNames.contains($0) }

        var range: (Date, Date)?
        let cal = Calendar.current
        if tokens.contains("bugün") || tokens.contains("today") {
            let s = cal.startOfDay(for: Date()); range = (s, Date())
            tokens.removeAll { $0 == "bugün" || $0 == "today" }
        } else if tokens.contains("dün") || tokens.contains("yesterday") {
            let s = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            range = (s, cal.startOfDay(for: Date()))
            tokens.removeAll { $0 == "dün" || $0 == "yesterday" }
        }
        return ParsedQuery(cleaned: tokens.joined(separator: " "),
                           colors: colors, dateRange: range)
    }
}
```

### 10.2 SearchService.swift

```swift
import Foundation
import GRDB

struct SearchService {
    let db = DatabaseManager.shared.dbPool
    private let repo = ItemRepository()

    func search(_ rawQuery: String, limit: Int = 50) async -> [Item] {
        let q = SearchQueryParser.parse(rawQuery)

        // 1) FTS5 keyword sıralaması (bm25)
        let ftsRanked = (try? ftsSearch(q.cleaned)) ?? []

        // 2) Vektör semantic sıralaması
        let vecRanked = vectorSearch(q.cleaned)

        // 3) Reciprocal Rank Fusion
        var score: [String: Double] = [:]
        let k = 60.0
        for (i, id) in ftsRanked.enumerated() { score[id, default: 0] += 1.0/(k + Double(i)) }
        for (i, id) in vecRanked.enumerated() { score[id, default: 0] += 1.0/(k + Double(i)) }

        // 4) Renk / tarih filtreleri (boost + filtre)
        var ids = Array(score.keys)
        var items = (try? fetchItems(ids)) ?? []

        if !q.colors.isEmpty {
            items = items.filter { item in !Set(item.colors).isDisjoint(with: q.colors) }
        }
        if let r = q.dateRange {
            items = items.filter { $0.createdAt >= r.start && $0.createdAt <= r.end }
        }
        // Sadece renk/tarih sorgusu (kelime yok) ise: tüm eşleşenleri getir
        if q.cleaned.trimmingCharacters(in: .whitespaces).isEmpty,
           (!q.colors.isEmpty || q.dateRange != nil) {
            items = (try? colorDateOnly(colors: q.colors, range: q.dateRange)) ?? items
        }

        return items
            .sorted { (score[$0.id] ?? 0) > (score[$1.id] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: FTS5
    private func ftsSearch(_ query: String) throws -> [String] {
        guard !query.isEmpty, let pattern = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        return try db.read { d in
            let sql = """
            SELECT item.id AS id, bm25(item_fts) AS rank
            FROM item
            JOIN item_fts ON item_fts.rowid = item.rowid
            WHERE item_fts MATCH ? AND item.forgotten = 0
            ORDER BY rank
            LIMIT 200
            """
            let rows = try Row.fetchAll(d, sql: sql, arguments: [pattern])
            return rows.map { $0["id"] as String }
        }
    }

    // MARK: Vektör
    private func vectorSearch(_ query: String) -> [String] {
        guard !query.isEmpty, let qv = EmbeddingService.embed(query) else { return [] }
        let all = (try? repo.allEmbeddings()) ?? []
        return all
            .map { (id: $0.id, s: VectorStore.cosine(qv, $0.vec)) }
            .filter { $0.s > 0.15 }
            .sorted { $0.s > $1.s }
            .prefix(200)
            .map { $0.id }
    }

    // MARK: yardımcı çekme
    private func fetchItems(_ ids: [String]) throws -> [Item] {
        try db.read { d in try Item.filter(ids.contains(Column("id"))).fetchAll(d) }
    }

    private func colorDateOnly(colors: [String], range: (start: Date, end: Date)?) throws -> [Item] {
        try db.read { d in
            var q = Item.filter(Column("forgotten") == false)
            if let r = range {
                q = q.filter(Column("createdAt") >= r.start && Column("createdAt") <= r.end)
            }
            let items = try q.order(Column("createdAt").desc).fetchAll(d)
            guard !colors.isEmpty else { return items }
            return items.filter { !Set($0.colors).isDisjoint(with: colors) }
        }
    }

    // MARK: Same Vibe
    func similarImages(to itemId: String, limit: Int = 12) -> [Item] {
        guard let target = try? repo.item(id: itemId), let tfp = target.featurePrint else { return [] }
        let others = (try? repo.allFeaturePrints(excluding: itemId)) ?? []
        let ranked = others.compactMap { o -> (String, Float)? in
            guard let d = VisionService.distance(tfp, o.fp) else { return nil }
            return (o.id, d)
        }
        .sorted { $0.1 < $1.1 }          // küçük mesafe = benzer
        .prefix(limit)
        .map { $0.0 }
        return (try? fetchItems(ranked)) ?? []
    }
}
```

> **Ölçek notu:** birkaç bin item'da brute-force cosine + feature print mesafesi anlık. 10k+ olunca `sqlite-vec` veya in-memory HNSW ekle; arayüz değişmez.

---

## 11. Sync Layer — CloudKit (Phase 3, $0, additive)

> **Offline-first.** Uygulama sync olmadan tam çalışır. CloudKit yalnızca cihazlar arası kopyalar; inference yapmaz. Private database kullanıcının iCloud kotasından düşer → sana maliyet yok. Bu, sheet'in **en ağır modülü**; MVP'den sonra ekle.

### 11.1 Tasarım
- **Private DB + custom zone** (`zihinZone`) → zone-level change tracking.
- Her `Item` → bir `CKRecord` (recordType `"Item"`).
- **Push:** `dirty == true` olan kayıtları yükle, `dirty=false` yap, `ckSystemFields`'i sakla.
- **Pull:** `CKFetchRecordZoneChangesOperation` + saklı `serverChangeToken` → değişenleri lokale yaz.
- **Conflict:** last-writer-wins (`updatedAt` karşılaştır).
- Asset'ler (görsel/video) → `CKAsset` olarak ilişkilendir (opsiyonel; başlangıçta sadece metadata sync et, asset'leri cihazda tut).

### 11.2 CloudKitSyncService.swift (çekirdek iskelet)

```swift
import CloudKit
import GRDB
import Foundation

final class CloudKitSyncService {
    static let shared = CloudKitSyncService()
    private let container = CKContainer(identifier: "iCloud.app.zihin")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "zihinZone", ownerName: CKCurrentUserDefaultName)
    private let repo = ItemRepository()
    private let pool = DatabaseManager.shared.dbPool

    private let tokenKey = "ck.serverChangeToken"

    func bootstrap() async {
        // Zone'u garanti et
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try? await db.modifyRecordZones(saving: [zone], deleting: [])
    }

    // MARK: Push
    func pushDirty() async {
        let dirtyItems: [Item] = (try? pool.read { d in
            try Item.filter(Column("dirty") == true).fetchAll(d)
        }) ?? []
        guard !dirtyItems.isEmpty else { return }

        let records = dirtyItems.map { recordFromItem($0) }
        do {
            let result = try await db.modifyRecords(saving: records, deleting: [])
            // Başarılı kayıtlar için dirty=false + systemFields sakla
            for (recordID, res) in result.saveResults {
                if case .success(let record) = res {
                    let id = recordID.recordName
                    let sysData = encodeSystemFields(record)
                    try? pool.write { d in
                        try Item.filter(key: id).updateAll(d,
                            Column("dirty").set(to: false),
                            Column("ckSystemFields").set(to: sysData))
                    }
                }
            }
        } catch { print("CK push error: \(error)") }
    }

    // MARK: Pull
    func pullChanges() async {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = loadToken()

        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config])

        op.recordWasChangedBlock = { [weak self] _, result in
            if case .success(let record) = result { self?.applyRemote(record) }
        }
        op.recordWithIDWasDeletedBlock = { [weak self] recordID, _ in
            try? self?.pool.write { d in
                _ = try Item.deleteOne(d, key: recordID.recordName)
            }
        }
        op.recordZoneChangeTokensUpdatedBlock = { [weak self] _, token, _ in
            self?.saveToken(token)
        }
        op.recordZoneFetchResultBlock = { [weak self] _, result in
            if case .success(let (token, _, _)) = result { self?.saveToken(token) }
        }
        db.add(op)
    }

    // MARK: Map
    private func recordFromItem(_ item: Item) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.id, zoneID: zoneID)
        let record: CKRecord
        if let data = item.ckSystemFields, let decoded = decodeSystemFields(data, id: recordID) {
            record = decoded
        } else {
            record = CKRecord(recordType: "Item", recordID: recordID)
        }
        record["type"] = item.type.rawValue as CKRecordValue
        record["createdAt"] = item.createdAt as CKRecordValue
        record["updatedAt"] = item.updatedAt as CKRecordValue
        record["title"] = item.title as CKRecordValue?
        record["url"] = item.url as CKRecordValue?
        record["textContent"] = item.textContent as CKRecordValue?
        record["summary"] = item.summary as CKRecordValue?
        record["ocrText"] = item.ocrText as CKRecordValue?
        record["transcript"] = item.transcript as CKRecordValue?
        record["frameText"] = item.frameText as CKRecordValue?
        record["dominantColors"] = item.dominantColors as CKRecordValue?
        record["siteName"] = item.siteName as CKRecordValue?
        record["isPinned"] = (item.isPinned ? 1 : 0) as CKRecordValue
        record["forgotten"] = (item.forgotten ? 1 : 0) as CKRecordValue
        if let e = item.embedding { record["embedding"] = e as CKRecordValue }
        if let f = item.featurePrint { record["featurePrint"] = f as CKRecordValue }
        return record
    }

    private func applyRemote(_ record: CKRecord) {
        let id = record.recordID.recordName
        let remoteUpdated = (record["updatedAt"] as? Date) ?? .distantPast
        let local = try? repo.item(id: id)
        if let local, local.updatedAt >= remoteUpdated { return }  // LWW

        var item = local ?? Item(type: .note)
        item.id = id
        item.type = ItemType(rawValue: record["type"] as? String ?? "note") ?? .note
        item.createdAt = record["createdAt"] as? Date ?? Date()
        item.updatedAt = remoteUpdated
        item.title = record["title"] as? String
        item.url = record["url"] as? String
        item.textContent = record["textContent"] as? String
        item.summary = record["summary"] as? String
        item.ocrText = record["ocrText"] as? String
        item.transcript = record["transcript"] as? String
        item.frameText = record["frameText"] as? String
        item.dominantColors = record["dominantColors"] as? String
        item.siteName = record["siteName"] as? String
        item.isPinned = (record["isPinned"] as? Int ?? 0) == 1
        item.forgotten = (record["forgotten"] as? Int ?? 0) == 1
        item.embedding = record["embedding"] as? Data
        item.featurePrint = record["featurePrint"] as? Data
        item.ckSystemFields = encodeSystemFields(record)
        item.dirty = false
        try? pool.write { d in try item.save(d) }
    }

    // MARK: systemFields & token
    private func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        return coder.encodedData
    }
    private func decodeSystemFields(_ data: Data, id: CKRecord.ID) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let rec = CKRecord(coder: coder); coder.finishDecoding(); return rec
    }
    private func saveToken(_ token: CKServerChangeToken?) {
        guard let token else { return }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: tokenKey)
    }
    private func loadToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
```

> **CloudKit schema:** Development environment'ta ilk push, alanları otomatik oluşturur. Production'a geçerken CloudKit Dashboard'da schema'yı deploy et. Sorgulanabilir alanlar için (örn. `updatedAt`) Dashboard'da "Sortable/Queryable" işaretle.
> **Ne zaman çalıştır:** app foreground'a gelince `bootstrap()` → `pushDirty()` → `pullChanges()`. İleride CloudKit push notification ile tetikle.

---

## 12. UI Layer (SwiftUI)

> Aşağıda app girişi, ana store, TimelineView, CardView ve ArticleDetail **tam kod**; diğer detail/spaces/settings için net spec + iskelet. Hepsi aynı kalıbı izler.

### 12.1 App/ZihinApp.swift + LibraryStore

```swift
import SwiftUI

@main
struct ZihinApp: App {
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    store.reload()
                    // Phase 3:
                    // await CloudKitSyncService.shared.bootstrap()
                    // await CloudKitSyncService.shared.pushDirty()
                    // await CloudKitSyncService.shared.pullChanges()
                }
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var items: [Item] = []
    @Published var searchResults: [Item]? = nil
    private let repo = ItemRepository()
    private let searchService = SearchService()

    func reload() {
        items = (try? repo.timeline()) ?? []
    }
    func search(_ q: String) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = nil; return }
        Task {
            let r = await searchService.search(q)
            await MainActor.run { self.searchResults = r }
        }
    }
    func clearSearch() { searchResults = nil }

    func addNote(_ text: String) {
        Task {
            _ = await IngestionService.shared.ingest(.text(text))
            await MainActor.run { self.reload() }
        }
    }
    func togglePin(_ item: Item) {
        try? repo.setPinned(!item.isPinned, id: item.id); reload()
    }
    func forget(_ item: Item) {
        try? repo.setForgotten(true, id: item.id); reload()
    }
}
```

### 12.2 RootView (tab yapısı)

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TimelineView().tabItem { Label("Zihin", systemImage: "square.grid.2x2") }
            SearchView().tabItem { Label("Ara", systemImage: "magnifyingglass") }
            SpacesView().tabItem { Label("Space'ler", systemImage: "folder") }
            SerendipityView().tabItem { Label("Keşfet", systemImage: "sparkles") }
            SettingsView().tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
    }
}
```

### 12.3 TimelineView + CardView (tam)

```swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showNewNote = false
    @State private var noteText = ""

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.items) { item in
                        NavigationLink(value: item.id) {
                            CardView(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(item.isPinned ? "Sabitlemeyi kaldır" : "Sabitle") {
                                store.togglePin(item)
                            }
                            Button("Unut", role: .destructive) { store.forget(item) }
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Zihin")
            .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
            .toolbar {
                Button { showNewNote = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showNewNote) {
                NewNoteSheet(text: $noteText) {
                    store.addNote(noteText); noteText = ""; showNewNote = false
                }
            }
            .refreshable { store.reload() }
        }
    }
}

struct CardView: View {
    let item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item.type {
            case .image:
                LocalImage(relative: item.assetPath).aspectRatio(contentMode: .fill)
                    .frame(height: 160).clipped().cornerRadius(12)
            case .video:
                ZStack(alignment: .bottomLeading) {
                    LocalImage(relative: item.posterPath ?? item.assetPath)
                        .aspectRatio(contentMode: .fill).frame(height: 160).clipped()
                    Image(systemName: "play.circle.fill").font(.title).padding(6)
                }.cornerRadius(12)
            case .link:
                VStack(alignment: .leading, spacing: 4) {
                    LocalImage(relative: item.posterPath)
                        .aspectRatio(contentMode: .fill).frame(height: 110).clipped()
                    Text(item.title ?? item.url ?? "").font(.subheadline).lineLimit(2)
                    Text(item.siteName ?? "").font(.caption2).foregroundStyle(.secondary)
                }.padding(8).background(.gray.opacity(0.08)).cornerRadius(12)
            case .pdf:
                HStack { Image(systemName: "doc.richtext"); Text(item.title ?? "PDF").lineLimit(2) }
                    .padding().frame(maxWidth: .infinity, minHeight: 120)
                    .background(.gray.opacity(0.08)).cornerRadius(12)
            case .note, .quote:
                Text(item.textContent ?? "").font(.callout).lineLimit(8)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12)).cornerRadius(12)
            }
            if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
        }
    }
}

/// App Group asset'ini yükleyen basit görsel.
struct LocalImage: View {
    let relative: String?
    var body: some View {
        if let relative, let ui = UIImage(contentsOfFile: AssetStore.url(for: relative).path) {
            Image(uiImage: ui).resizable()
        } else {
            Rectangle().fill(.gray.opacity(0.15))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

struct NewNoteSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding()
                .navigationTitle("Yeni Not")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kaydet", action: onSave) } }
        }
    }
}
```

### 12.4 DetailRouter + ArticleDetailView (tam) + diğer detail spec

```swift
import SwiftUI
import WebKit
import AVKit

struct DetailRouter: View {
    let itemId: String
    private let repo = ItemRepository()
    var body: some View {
        if let item = try? repo.item(id: itemId) {
            switch item.type {
            case .link where item.readerHTML != nil: ArticleDetailView(item: item)
            case .video: VideoDetailView(item: item)
            case .image: ImageDetailView(item: item)
            default: NoteDetailView(item: item)
            }
        } else { Text("Bulunamadı") }
    }
}

struct ArticleDetailView: View {
    let item: Item
    var body: some View {
        WebView(html: item.readerHTML ?? "<p>\(item.textContent ?? "")</p>")
            .navigationTitle(item.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct WebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(html, baseURL: nil)
    }
}

struct VideoDetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let p = item.assetPath {
                    VideoPlayer(player: AVPlayer(url: AssetStore.url(for: p)))
                        .frame(height: 240)
                }
                if let t = item.transcript, !t.isEmpty {
                    Text("Konuşma").font(.headline); Text(t).font(.callout)
                }
                if let f = item.frameText, !f.isEmpty {
                    Text("Karelerdeki yazı").font(.headline); Text(f).font(.caption)
                }
            }.padding()
        }.navigationTitle(item.title ?? "Video")
    }
}

struct ImageDetailView: View {
    let item: Item
    @State private var similar: [Item] = []
    private let search = SearchService()
    var body: some View {
        ScrollView {
            LocalImage(relative: item.assetPath).aspectRatio(contentMode: .fit)
            if !(item.ocrText ?? "").isEmpty {
                Text(item.ocrText!).font(.callout).padding()
            }
            if !similar.isEmpty {
                Text("Same Vibe").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                ScrollView(.horizontal) {
                    HStack { ForEach(similar) { s in
                        LocalImage(relative: s.assetPath ?? s.posterPath)
                            .frame(width: 120, height: 120).clipped().cornerRadius(10)
                    } }.padding(.horizontal)
                }
            }
        }
        .navigationTitle("Görsel")
        .task { similar = search.similarImages(to: item.id) }
    }
}

struct NoteDetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = item.summary, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
                Text(item.textContent ?? "").font(.body)
                if let u = item.url { Link("Kaynağı aç", destination: URL(string: u)!) }
            }.padding()
        }.navigationTitle(item.title ?? "Not")
    }
}
```

### 12.5 SearchView (tam)

```swift
import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.searchResults ?? []) { item in
                        NavigationLink(value: item.id) { CardView(item: item) }.buttonStyle(.plain)
                    }
                }.padding(12)
            }
            .navigationTitle("Ara")
            .navigationDestination(for: String.self) { DetailRouter(itemId: $0) }
            .searchable(text: $query, prompt: "renk, kelime, brand, tarih…")
            .onChange(of: query) { _, q in store.search(q) }
            .onSubmit(of: .search) { store.search(query) }
        }
    }
}
```

### 12.6 SerendipityView (tam) — keep/forget

```swift
import SwiftUI

struct SerendipityView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var deck: [Item] = []
    var body: some View {
        NavigationStack {
            VStack {
                if let top = deck.first {
                    CardView(item: top).padding()
                    HStack(spacing: 24) {
                        Button { store.forget(top); advance() } label: {
                            Label("Unut", systemImage: "trash").foregroundStyle(.red)
                        }
                        Button { advance() } label: {
                            Label("Sakla", systemImage: "checkmark").foregroundStyle(.green)
                        }
                    }.padding()
                } else {
                    ContentUnavailableView("Bugünlük bu kadar", systemImage: "sparkles")
                }
            }
            .navigationTitle("Keşfet")
            .task { deck = store.items.filter { !$0.forgotten }.shuffled() }
        }
    }
    private func advance() { if !deck.isEmpty { deck.removeFirst() } }
}
```

### 12.7 Diğer view spec'leri (aynı kalıp)
- **SpacesView:** `space` tablosundan listele; "+ Smart Space" → ad + arama metni gir → `Space(isSmart:true, query:)` kaydet. Açınca `SearchService.search(space.query)` sonucu grid. Manuel space için `item_tag` üzerinden filtre.
- **SettingsView:** toggle'lar — E3 encryption durumu, E5 "On-device LLM (deneysel)" switch, E1 "Obsidian klasörü seç" (UIDocumentPicker), "Tümünü Obsidian'a aktar", sync durumu, "Instagram ipucu: video içeriği için ekran kaydı paylaş".

---

## 13. Eklentiler E1–E5 (tam kod)

> **Önemli:** Bölüm 5.2 `KeychainKey.databasePassphrase()`'i (E3) ve Bölüm 7.2 `DomainEnricher.enrich(url:base:)`'i (E4) **çağırıyor**. İkisi de aşağıda implemente edildi; aksi halde proje derlenmez.

### E1 — ObsidianExporter.swift (Markdown + frontmatter export)

Önce `ItemRepository`'ye küçük bir yardımcı ekle (ObsidianExporter ve graph için lazım):

```swift
// ItemRepository.swift içine ekle:
extension ItemRepository {
    func tags(for itemId: String) throws -> [String] {
        try db.read { d in
            let sql = """
            SELECT tag.name FROM tag
            JOIN item_tag ON item_tag.tagId = tag.id
            WHERE item_tag.itemId = ?
            """
            return try String.fetchAll(d, sql: sql, arguments: [itemId])
        }
    }
}
```

```swift
import Foundation

enum ObsidianExporter {
    /// Tek item -> Obsidian uyumlu markdown (YAML frontmatter + gövde).
    static func markdown(for item: Item, tags: [String]) -> String {
        let iso = ISO8601DateFormatter()
        var fm = "---\n"
        fm += "id: \(item.id)\n"
        fm += "type: \(item.type.rawValue)\n"
        fm += "created: \(iso.string(from: item.createdAt))\n"
        if let t = item.title { fm += "title: \"\(escape(t))\"\n" }
        if let u = item.url { fm += "url: \(u)\n" }
        if let s = item.siteName { fm += "site: \(s)\n" }
        if !tags.isEmpty { fm += "tags: [\(tags.map { "\"\(escape($0))\"" }.joined(separator: ", "))]\n" }
        if !item.colors.isEmpty { fm += "colors: [\(item.colors.joined(separator: ", "))]\n" }
        fm += "---\n\n"

        var body = ""
        if let t = item.title { body += "# \(t)\n\n" }
        if let s = item.summary, !s.isEmpty { body += "> \(s)\n\n" }
        if let text = item.textContent, !text.isEmpty { body += text + "\n\n" }
        if let ocr = item.ocrText, !ocr.isEmpty { body += "## OCR\n\n\(ocr)\n\n" }
        if let tr = item.transcript, !tr.isEmpty { body += "## Transcript\n\n\(tr)\n\n" }
        if let ft = item.frameText, !ft.isEmpty { body += "## Karelerdeki yazı\n\n\(ft)\n\n" }
        return fm + body
    }

    /// Tüm kütüphaneyi seçilen klasöre yazar (UIDocumentPicker'dan gelen security-scoped URL).
    static func exportAll(to folder: URL) throws {
        let repo = ItemRepository()
        let items = try repo.timeline(includeForgotten: true)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }

        for item in items {
            let tags = (try? repo.tags(for: item.id)) ?? []
            let md = markdown(for: item, tags: tags)
            let base = (item.title ?? item.id)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(60)
            let name = "\(base)-\(item.id.prefix(6)).md"
            let url = folder.appendingPathComponent(name)
            try md.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
```

**Settings'te klasör seçimi (SwiftUI):**
```swift
import SwiftUI
import UniformTypeIdentifiers

struct ObsidianExportButton: View {
    @State private var picking = false
    var body: some View {
        Button("Tümünü Obsidian'a aktar") { picking = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                try? ObsidianExporter.exportAll(to: url)
            }
        }
    }
}
```

### E2 — KnowledgeGraph.swift (kenar hesabı) + GraphView (Canvas)

```swift
import Foundation

struct GraphNode: Identifiable { let id: String; let title: String }
struct GraphEdge: Identifiable { let id = UUID(); let a: String; let b: String; let weight: Float }

enum KnowledgeGraph {
    /// Embedding cosine'i eşik üstündeyse kenar üret (her düğüm için en güçlü `maxPerNode`).
    static func build(threshold: Float = 0.45, maxPerNode: Int = 4) -> (nodes: [GraphNode], edges: [GraphEdge]) {
        let repo = ItemRepository()
        let embs = (try? repo.allEmbeddings()) ?? []
        let items = (try? repo.timeline()) ?? []
        let titleByID = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, $0.title ?? $0.textContent?.prefix(24).description ?? $0.type.rawValue)
        })

        var edges: [GraphEdge] = []
        var seen = Set<String>()
        for i in 0..<embs.count {
            var neighbors: [(String, Float)] = []
            for j in 0..<embs.count where i != j {
                let s = VectorStore.cosine(embs[i].vec, embs[j].vec)
                if s >= threshold { neighbors.append((embs[j].id, s)) }
            }
            for (b, w) in neighbors.sorted(by: { $0.1 > $1.1 }).prefix(maxPerNode) {
                let key = [embs[i].id, b].sorted().joined(separator: "|")
                if seen.insert(key).inserted {
                    edges.append(GraphEdge(a: embs[i].id, b: b, weight: w))
                }
            }
        }
        let usedIDs = Set(edges.flatMap { [$0.a, $0.b] })
        let nodes = usedIDs.map { GraphNode(id: $0, title: titleByID[$0] ?? "—") }
        return (nodes, edges)
    }
}
```

```swift
import SwiftUI

/// Basit force-directed layout. Birkaç yüz düğüme kadar akıcı.
struct GraphView: View {
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var pos: [String: CGPoint] = [:]
    @State private var vel: [String: CGVector] = [:]
    let timer = Timer.publish(every: 1/30, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { ctx, size in
            // kenarlar
            for e in edges {
                guard let a = pos[e.a], let b = pos[e.b] else { continue }
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(.gray.opacity(0.4)),
                           lineWidth: CGFloat(e.weight) * 2)
            }
            // düğümler
            for n in nodes {
                guard let p = pos[n.id] else { continue }
                let r: CGFloat = 6
                ctx.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)),
                         with: .color(.accentColor))
                ctx.draw(Text(n.title).font(.system(size: 9)),
                         at: CGPoint(x: p.x, y: p.y + 12))
            }
        }
        .onAppear { load() }
        .onReceive(timer) { _ in step(canvas: CGSize(width: 350, height: 600)) }
        .navigationTitle("Bağlantılar")
    }

    private func load() {
        let g = KnowledgeGraph.build()
        nodes = g.nodes; edges = g.edges
        for (i, n) in nodes.enumerated() {
            let angle = Double(i) / Double(max(1, nodes.count)) * 2 * .pi
            pos[n.id] = CGPoint(x: 175 + 120*cos(angle), y: 300 + 120*sin(angle))
            vel[n.id] = .zero
        }
    }

    /// Tek simülasyon adımı: repulsion (tüm çiftler) + spring (kenarlar) + merkez çekim.
    private func step(canvas: CGSize) {
        let center = CGPoint(x: canvas.width/2, y: canvas.height/2)
        var force: [String: CGVector] = [:]
        for n in nodes { force[n.id] = .zero }

        // repulsion
        for i in 0..<nodes.count {
            for j in (i+1)..<nodes.count {
                let a = nodes[i].id, b = nodes[j].id
                guard let pa = pos[a], let pb = pos[b] else { continue }
                let dx = pa.x - pb.x, dy = pa.y - pb.y
                let dist = max(1, sqrt(dx*dx + dy*dy))
                let rep = 1200 / (dist*dist)
                force[a]!.dx += dx/dist * rep; force[a]!.dy += dy/dist * rep
                force[b]!.dx -= dx/dist * rep; force[b]!.dy -= dy/dist * rep
            }
        }
        // springs
        for e in edges {
            guard let pa = pos[e.a], let pb = pos[e.b] else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let dist = max(1, sqrt(dx*dx + dy*dy))
            let k = 0.02 * Double(dist - 80)
            force[e.a]!.dx += dx/dist * k; force[e.a]!.dy += dy/dist * k
            force[e.b]!.dx -= dx/dist * k; force[e.b]!.dy -= dy/dist * k
        }
        // merkez + integrate
        for n in nodes {
            guard var p = pos[n.id], var v = vel[n.id], let f = force[n.id] else { continue }
            v.dx = (v.dx + f.dx + (center.x - p.x)*0.002) * 0.85
            v.dy = (v.dy + f.dy + (center.y - p.y)*0.002) * 0.85
            p.x += v.dx; p.y += v.dy
            pos[n.id] = p; vel[n.id] = v
        }
    }
}
```

### E3 — Features/Crypto/Keychain.swift (E2E encryption anahtarı)

```swift
import Foundation
import Security

/// SQLCipher passphrase'ini Keychain'de saklar/üretir.
/// Share Extension de şifreli DB'yi açacağı için anahtar PAYLAŞILAN keychain access group'ta olmalı.
enum KeychainKey {
    private static let service = "app.zihin.db"
    private static let account = "db-passphrase"
    // Keychain Sharing capability ile eşleşmeli (app + extension iki target'ta da):
    private static let accessGroup = "$(AppIdentifierPrefix)app.zihin.shared" // gerçek prefix'i entitlement'tan al

    static func databasePassphrase() throws -> String {
        if let existing = try? read() { return existing }
        let new = generate()
        try store(new)
        return new
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // accessGroup'u runtime'da entitlement'tan çözülen gerçek değerle set et.
        // Geliştirme aşamasında tek target ise bu satırı kaldırabilirsin.
        // q[kSecAttrAccessGroup as String] = accessGroup
        return q
    }

    private static func store(_ value: String) throws {
        var q = baseQuery()
        q[kSecValueData as String] = value.data(using: .utf8)!
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func read() throws -> String {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { throw KeychainError.status(status) }
        return s
    }

    enum KeychainError: Error { case status(OSStatus) }
}
```

**E3'ü etkinleştirme:**
1. SPM'de **GRDB-with-SQLCipher** ürününü seç.
2. Build Settings → **Active Compilation Conditions**'a `ZIHIN_ENCRYPTED` ekle (Bölüm 5.2'deki `#if` bunu görür).
3. App + Extension iki target'ta da **Keychain Sharing** capability → aynı access group. `baseQuery()`'de `kSecAttrAccessGroup`'u gerçek prefix'le aç.
4. **Uyarı:** Var olan şifresiz DB'yi sonradan şifrelemek migration gerektirir. Şifrelemeyi **baştan** aç ya da ilk sürümde karar ver.

### E4 — DomainEnricher.swift (rich content-type kartları)

```swift
import Foundation

enum DomainEnricher {
    /// Domain'e özel ekstra metadata. Sonuç meta_field'e yazılır (IngestionService.ingestLink).
    static func enrich(url: URL, base: LinkMetadata) async -> [String: String] {
        guard let host = url.host?.lowercased() else { return [:] }
        if host.contains("github.com")  { return await github(url) }
        if host.contains("youtube.com") || host.contains("youtu.be") { return youtube(base) }
        if host.contains("twitter.com") || host.contains("x.com") {
            return ["kind": "tweet", "author": base.siteName ?? ""]
        }
        if let price = base.price { return ["kind": "product", "price": price] }
        return [:]
    }

    private static func github(_ url: URL) async -> [String: String] {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return ["kind": "github"] }
        let api = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ZihinApp/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["kind": "github"] }
        var meta = ["kind": "github"]
        if let stars = json["stargazers_count"] as? Int { meta["stars"] = String(stars) }
        if let lang  = json["language"] as? String { meta["language"] = lang }
        if let desc  = json["description"] as? String { meta["description"] = desc }
        if let owner = (json["owner"] as? [String: Any])?["login"] as? String { meta["owner"] = owner }
        return meta
    }

    private static func youtube(_ base: LinkMetadata) -> [String: String] {
        var meta = ["kind": "youtube"]
        if let ch = base.siteName { meta["channel"] = ch }
        if let d = base.description { meta["caption"] = String(d.prefix(200)) }
        return meta
    }
}
```

> UI: CardView/DetailView'da `meta_field`'i okuyup rozet göster (örn. GitHub için ⭐ stars + language). `MetaField` sorgusu için `ItemRepository`'ye basit `meta(for:)` ekleyebilirsin (tags(for:) ile aynı kalıp).

### E5 — Features/LocalLLM.swift (opsiyonel on-device LLM, DEFAULT KAPALI)

```swift
import Foundation

/// E5 — Deneysel on-device LLM (abstractive summary / Q&A).
/// DEFAULT KAPALI. Açıkken extractive SummaryService yerine bunu kullanabilirsin.
/// Stack: MLX Swift + küçük quantized model (örn. mlx-community/Llama-3.2-1B-Instruct-4bit).
enum LocalLLM {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "settings.localLLM.enabled")
    }

    /// Entegrasyon adımları:
    /// 1) SPM: https://github.com/ml-explore/mlx-swift-examples  (MLXLLM hedefi)
    /// 2) Model: ilk açılışta Hugging Face'ten indir + cache (≈0.7–1 GB, sadece yeni cihazlar).
    /// 3) generate(prompt:) async throws -> String
    static func summarizeAbstractive(_ text: String) async -> String? {
        guard isEnabled else { return nil }
        // let container = try await LLMModelFactory.shared.loadContainer(
        //     configuration: .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit"))
        // return try await container.generate(prompt: "Aşağıdaki metni 2 cümlede özetle:\n\(text)")
        return nil // model entegre edilene kadar nil -> çağıran taraf extractive'e düşer
    }
}
```

**Neden default kapalı:** model büyük (RAM + indirme), eski cihazlarda ağır, pil yer. ZIHIN'in tezi "sıfır maliyet + hızlı"; extractive summary (Bölüm 6.5) bunu zaten karşılıyor. LLM yalnızca isteyen güçlü cihaz kullanıcıları için. **Yine de $0** (cihazda çalışır, API yok).

---

## 14. İzinler & Gizlilik

### 14.1 Info.plist anahtarları (Bölüm 3.7 ile aynı — tek yerde)
| Key | Neden |
|---|---|
| `NSPhotoLibraryUsageDescription` | Görsel/video içe aktarma |
| `NSSpeechRecognitionUsageDescription` | Video STT (on-device) |
| `NSMicrophoneUsageDescription` | Sesli not / kayıt işleme |
| `NSCameraUsageDescription` | Doğrudan foto/tarama (kamera kullanırsan) |

### 14.2 Entitlements
- **App Groups:** `group.app.zihin` (app + extension).
- **iCloud / CloudKit:** `iCloud.app.zihin` (Phase 3).
- **Keychain Sharing:** E3 açıksa, app + extension ortak access group.
- **Background Modes:** remote-notification (Phase 3, CloudKit push).

### 14.3 App Store Privacy Nutrition Label (güçlü satış noktası)
ZIHIN ham veriyi **toplamaz**; her şey cihazda + kullanıcının kendi iCloud'unda (private DB).
- **Data Not Collected** işaretle (developer veriye erişmiyor).
- CloudKit private database "developer tarafından toplanan veri" sayılmaz — yine de App Review notuna yaz: *"All processing on-device (Vision/NaturalLanguage). Sync via user's private CloudKit. No third-party servers, no analytics, no tracking."*
- Tracking yok → ATT (App Tracking Transparency) gerekmez.

---

## 15. Build, Test & Ship

### 15.1 Signing
1. Apple Developer hesabı (99$/yıl).
2. App target + ShareExtension target → **Automatically manage signing**, Team seç.
3. Bundle ID'ler: `app.zihin.Zihin` ve `app.zihin.Zihin.ShareExtension` (extension, app'in alt-ID'si olmalı).

### 15.2 Test
- **Cihazda** test et (Vision/Speech Simulator'da sınırlı/yavaş).
- Akış testleri: not ekle → ara; Safari'den link paylaş; Instagram linki paylaş; Photos'tan görsel paylaş; ekran kaydı paylaş (video pipeline); PDF paylaş.
- Performans: 20–30 kareli video STT süresi; 1000+ item'da arama gecikmesi.

### 15.3 TestFlight & App Store Connect
1. Archive (**Product → Archive**) → Distribute App → App Store Connect → Upload.
2. App Store Connect'te uygulama kaydı, ekran görüntüleri, açıklama.
3. **Privacy:** Bölüm 14.3.
4. **Review notes:** on-device ML + private CloudKit + tracking yok olduğunu açıkça yaz (reviewer'ın işini kolaylaştırır).
5. **Instagram konusu:** App Review, scraping'i sorgularsa → "Kullanıcının paylaştığı public OG metadata'yı işliyoruz; tam video içeriği için kullanıcının kendi ekran kaydını kullanıyoruz" de. Otomatik toplu scraping YOK.

---

## 16. Roadmap — Fazlı İnşa Sırası (her fazda DoD)

| Faz | Kapsam | Definition of Done |
|---|---|---|
| **P0 — Skeleton** | Proje + Share Extension + App Group + DB migration + not ekle | Uygulama açılır, not eklenir, timeline'da görünür |
| **P1 — Image+Search** | Image ingest + Vision (OCR/classify/featureprint) + FTS5 + vektör + SearchView + Same Vibe | Görsel kaydet → içindeki yazıyla ara → bulunur; Same Vibe çalışır |
| **P2 — Link+Social (Instagram)** | LinkMetadata + Readability + SocialIngestor + DomainEnricher (E4) | Instagram linki paylaş → poster OCR + caption ile aranır; makale reader mode açılır |
| **P3 — Video** | VideoEnrichment (frame sampling + on-device STT) | Ekran kaydı paylaş → konuşma + kare yazısı aranır |
| **P4 — PDF + Spaces + Serendipity** | PDFKit + SpacesView + SerendipityView | PDF metni aranır; smart space çalışır; keşfet keep/forget |
| **P5 — Sync** | CloudKitSyncService (push/pull/conflict) | İki cihazda aynı kayıtlar görünür |
| **P6 — Eklenti cilası** | E1 Obsidian export, E2 Graph, E3 encryption, E5 LLM toggle | Export dosya üretir; graph çizilir; şifreli DB açılır |

> **Tek kişilik tempo:** P0→P2 önce (asıl değer burada: capture + arama + Instagram). P3 video ikinci. Sync ve eklentiler en son.

---

## 17. Risk Register & Fallback'ler

| Risk | Etki | Fallback / Önlem |
|---|---|---|
| Instagram OG fetch login duvarına çarpar | Poster/caption gelmez | Kullanıcı **ekran kaydı** paylaşır → tam video pipeline; UI'da ipucu göster |
| `og:video` logged-out gelmez | Tam frame/STT yok | Poster OCR + caption ile aranabilir kart yeterli (mymind de böyle) |
| TR on-device STT desteklenmez (OS sürümü) | Video transcript boş | `supportsOnDeviceRecognition` guard'lı; yoksa server-based'e düş (ses Apple'a gider → Settings'te uyar) veya STT'yi atla |
| TR embedding kalitesi düşük (Apple EN fallback) | Semantic arama zayıf | Bölüm 6.3 Core ML multilingual modeli ekle (mimari aynı) |
| Uzun videoda Vision pahalı | Yavaş/pil | `maxFrames=20` tavan + `maximumSize` downscale |
| SQLCipher + Share Extension keychain | Extension DB açamaz | Keychain Sharing access group (Bölüm E3) |
| CloudKit schema/kota | Sync hatası | Development env auto-schema; production'da Dashboard deploy; asset'leri başta sync etme (sadece metadata) |
| FTS5 + content=item senkron bozulur | Arama eksik | GRDB `synchronize(withTable:)` trigger'ları kullan (manuel index yazma) |
| App Review gizlilik/scraping sorusu | Red riski | "On-device + private CloudKit + no tracking; sadece kullanıcının paylaştığı içerik" notu |

---

## Appendix

### A. Bağımlılıklar
| Paket | Ürün | Zorunlu? |
|---|---|---|
| GRDB.swift | `GRDB` veya `GRDB-with-SQLCipher` (E3) | ✅ |
| SwiftSoup | `SwiftSoup` | ✅ (link/OG parse) |
| mlx-swift-examples | `MLXLLM` | ⛔ opsiyonel (E5) |

### B. Model kaynakları
- **Embedding (TR, opsiyonel):** `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` → coremltools (Bölüm 6.3).
- **OCR / classification / feature print:** Apple Vision (yerleşik, model gerekmez).
- **STT:** Apple Speech (yerleşik).
- **LLM (E5, opsiyonel):** `mlx-community/Llama-3.2-1B-Instruct-4bit` (veya benzeri küçük quantized).

### C. Bu sheet ne kadar "tam"? (dürüst durum)
- **Tam kod (kopyala-derle):** Data (5), ML/Enrichment (6), Capture + Share Extension (7), Social/Instagram (8), Video+PDF (9), Search (10), CloudKit (11), App+Timeline+Card+Detail+Search+Serendipity (12), E1–E4 (13). E5 = entegrasyon spec'i (opsiyonel).
- **Spec (aynı kalıptan yaz):** SpacesView, SettingsView gövdesi (12.7), Readability (B) yüksek-sadakat yolu, `ItemRepository.meta(for:)`.
- **Sürüm doğrulaması:** Yalnızca *availability* bayraklarını cihazda doğrula — `supportsOnDeviceRecognition`, `AVAssetImageGenerator.image(at:)` (iOS 16+), SQLCipher ürünü. Kod bunlara guard'lı.

### D. Derleme sırası özet checklist
1. Bölüm 3 kurulum (targets, App Group, capabilities, SPM).
2. Bölüm 5 Data → derle.
3. Bölüm 6 ML servisleri → derle (her biri bağımsız).
4. Bölüm 7 Capture + Share Extension → "not ekle" + "görsel paylaş" testi.
5. Bölüm 10 Search + Bölüm 12 UI → arama uçtan uca.
6. Bölüm 8–9 Link/Social/Video → Instagram + ekran kaydı testi.
7. Bölüm 13 E1–E5.
8. Bölüm 11 Sync (en son).

### E. Küçük tutarlılık notları
- **ColorService → NamedColors köprüsü:** `ColorService.kMeans` çıktısını `NamedColors.nearest(to: (c.r, c.g, c.b))` (tuple imzası) ile çağır; `Support/NamedColors.swift`'teki `ColorServiceRGB` köprü tipi yalnızca derleme kolaylığı. İstersen `ColorService.RGB`'yi `internal` yapıp doğrudan kullan.
- **Actor re-entrancy:** `SocialIngestor` kendi item'ını **kendisi** persist eder (stateless servisler + `ItemRepository`), `IngestionService` actor'ına geri çağrı yapmaz — deadlock önlenir.
- **FTS5 rowid:** `item_fts` content=item ile senkron; join `item_fts.rowid = item.rowid` (implicit integer rowid).

*(Sheet sonu — ZIHIN v1)*
