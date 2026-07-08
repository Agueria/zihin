import Foundation
import UIKit

/// İki aşamalı capture'ın 2. aşaması (spec §3.2). YALNIZ ana app'te çalışır
/// (extension bellek limiti). Foreground'a geçişte AppRoot tetikler.
/// v2 (§4.1): embedding artık EmbeddingCoordinator üzerinden — chunk vektörleri, model
/// damgası ve μ toplamı da burada üretilir; merkezleme okuma anında yapılır.
actor EnrichmentQueue {
    static let shared = EnrichmentQueue()
    private let repo = ItemRepository()
    private var running = false

    enum EnrichError: Error { case badAsset, badURL }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        await EmbeddingCoordinator.shared.prepare()        // asset'leri hazırla (§2.3/§6)
        let pending = (try? repo.pendingItems()) ?? []
        for var item in pending {
            try? repo.setStatus(.enriching, id: item.id)
            do {
                let tags = try await enrich(&item)
                item.status = .ready
                try repo.save(&item)
                try repo.attachTags(Array(Set(tags)), to: item.id)
            } catch {
                try? repo.setStatus(.pending, id: item.id, bumpAttempts: true)
                if let cur = try? repo.item(id: item.id), cur.enrichAttempts >= 3 {
                    try? repo.setStatus(.failed, id: item.id)
                }
            }
        }
        // Donmuş μ'yu günde en çok bir kez tazele → space üyeliği & graph titremesin (§4.1b)
        try? DatabaseManager.shared.dbPool.write { db in
            try CenteringStore.refreshFrozenMuIfNeeded(db)
        }
    }

    private func enrich(_ item: inout Item) async throws -> [String] {
        switch item.type {
        case .note, .quote:
            let text = item.textContent ?? ""
            item.lang = LanguageService.dominantLanguage(text)
            item.summary = SummaryService.summarize(text, n: 2)
            await embed(&item, from: text)
            return LanguageService.namedEntities(text) + KeywordService.keywords(text)

        case .image:
            guard let path = item.assetPath,
                  let ui = UIImage(contentsOfFile: AssetStore.url(for: path).path),
                  let cg = ui.cgImage else { throw EnrichError.badAsset }
            let v = VisionService.analyze(cgImage: cg)
            item.ocrText = v.ocrText
            item.featurePrint = v.featurePrint
            item.colors = ColorService.dominantColorNames(cgImage: cg)
            item.lang = LanguageService.dominantLanguage(v.ocrText)
            let base = ([v.ocrText] + v.classifications).joined(separator: " ")
            await embed(&item, from: base)
            return v.classifications + item.colors + LanguageService.namedEntities(v.ocrText)

        case .link:
            let tags = try await LinkEnricher.enrich(&item)
            let base = [item.title, item.summary, item.textContent, item.ocrText]
                .compactMap { $0 }.joined(separator: " ")
            await embed(&item, from: base)
            return tags

        case .video:
            guard let path = item.assetPath else { throw EnrichError.badAsset }
            let r = await VideoEnrichmentService.enrich(url: AssetStore.url(for: path))
            item.frameText = r.frameText
            item.transcript = r.transcript
            item.durationSec = r.durationSec
            item.colors = r.colors
            item.featurePrint = r.featurePrint
            if item.posterPath == nil, let p = r.posterData {
                item.posterPath = AssetStore.save(p, ext: "jpg")
            }
            let base = [r.transcript, r.frameText].joined(separator: " ")
            item.lang = LanguageService.dominantLanguage(base)
            await embed(&item, from: base)
            return r.classifications + r.colors
                + LanguageService.namedEntities(base) + KeywordService.keywords(base)

        case .pdf:
            guard let path = item.assetPath else { throw EnrichError.badAsset }
            let text = PDFTextExtractor.extract(url: AssetStore.url(for: path))
            item.textContent = text
            item.summary = SummaryService.summarize(text, n: 3)
            item.lang = LanguageService.dominantLanguage(text)
            await embed(&item, from: text)
            return LanguageService.namedEntities(text) + KeywordService.keywords(text)
        }
    }

    /// v2 (§4.1): doküman vektörü + chunk'ları üret, kalıcılaştır, aktif modeli damgala,
    /// μ toplamına ekle, lemma gölge kolonunu doldur. Model inmemişse embedding boş kalır
    /// (§6 — indirilene kadar yalnız FTS5 ile çalışılır).
    private func embed(_ item: inout Item, from text: String) async {
        item.lemmaText = LanguageService.lemmatize(text)
        guard let result = await EmbeddingCoordinator.shared.embedDocument(text) else {
            item.embedding = nil
            return
        }
        item.embedding = VectorStore.encode(result.doc)
        await EmbeddingCoordinator.shared.stamp(&item)
        try? repo.saveChunks(result.chunks, itemId: item.id)
        let model = item.embeddingModel ?? ""
        let revision = item.embeddingRevision ?? 0
        try? DatabaseManager.shared.dbPool.write { db in
            try CenteringStore.runningAdd(result.doc, model: model, revision: revision, db)
        }
    }
}
