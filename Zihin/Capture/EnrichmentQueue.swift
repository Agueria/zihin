import Foundation
import UIKit

/// İki aşamalı capture'ın 2. aşaması (spec §3.2). YALNIZ ana app'te çalışır
/// (extension bellek limiti). Foreground'a geçişte AppRoot tetikler.
actor EnrichmentQueue {
    static let shared = EnrichmentQueue()
    private let repo = ItemRepository()
    private var running = false

    enum EnrichError: Error { case badAsset, badURL }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
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
    }

    /// F0: reindex — tüm item'ları yeniden işle + donmuş μ'yı tazeler
    func reindex() async {
        guard !running else { return }
        running = true
        defer { running = false }

        // Tüm item'ları pending yap
        try? repo.resetEmbeddingMetadata()
        let items = (try? repo.timeline()) ?? []

        for var item in items {
            try? repo.setStatus(.enriching, id: item.id)
            do {
                let tags = try await enrich(&item)
                item.status = .ready
                try repo.save(&item)
                try repo.attachTags(Array(Set(tags)), to: item.id)
            } catch {
                try? repo.setStatus(.pending, id: item.id, bumpAttempts: true)
            }
        }

        // F0: donmuş μ'yı yeniden hesapla
        await recomputeFrozenMean()
    }

    private func enrich(_ item: inout Item) async throws -> [String] {
        switch item.type {
        case .note, .quote:
            let text = item.textContent ?? ""
            item.lang = LanguageService.dominantLanguage(text)
            // F0: lemma
            item.lemmaText = LanguageService.lemma(text)
            item.summary = SummaryService.summarize(text, n: 2)

            // F0: chunking + embedding
            let chunks = Chunker.chunk(text)
            var chunkVectors: [(idx: Int, vector: Data)] = []
            var allVecs: [[Float]] = []
            for (i, chunk) in chunks.enumerated() {
                if let vecs = EmbeddingService.embed(chunk) {
                    for (j, v) in vecs.enumerated() {
                        chunkVectors.append((i * 10 + j, VectorStore.encode(v)))
                        allVecs.append(v)
                    }
                }
            }
            // Doküman ortalaması (konu ataması + graph için)
            if let mean = CorpusCentering.mean(vectors: allVecs) {
                item.embedding = VectorStore.encode(mean)
            }
            // Chunk vektörlerini kaydet
            try repo.saveChunks(itemId: item.id, chunks: chunkVectors)

            // F0: model versiyonlama
            let info = EmbeddingService.currentModelInfo
            item.embeddingModel = info.model
            item.embeddingRevision = info.revision

            // F2: topic sınıflandırma (lexicon + embedding prototip)
            try assignTopics(&item, allVecs: allVecs)

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
            item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)

            let info = EmbeddingService.currentModelInfo
            item.embeddingModel = info.model
            item.embeddingRevision = info.revision

            return v.classifications + item.colors + LanguageService.namedEntities(v.ocrText)

        case .link:
            return try await LinkEnricher.enrich(&item)

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
            item.embedding = EmbeddingService.embed(base).map(VectorStore.encode)

            let info = EmbeddingService.currentModelInfo
            item.embeddingModel = info.model
            item.embeddingRevision = info.revision

            return r.classifications + r.colors
                + LanguageService.namedEntities(base) + KeywordService.keywords(base)

        case .pdf:
            guard let path = item.assetPath else { throw EnrichError.badAsset }
            let text = PDFTextExtractor.extract(url: AssetStore.url(for: path))
            item.textContent = text
            item.lemmaText = LanguageService.lemma(text)
            item.summary = SummaryService.summarize(text, n: 3)
            item.lang = LanguageService.dominantLanguage(text)
            item.embedding = EmbeddingService.embed(text).map(VectorStore.encode)

            let info = EmbeddingService.currentModelInfo
            item.embeddingModel = info.model
            item.embeddingRevision = info.revision

            // F2: topic sınıflandırma
            try assignTopics(&item, allVecs: allVecs)

            return LanguageService.namedEntities(text) + KeywordService.keywords(text)
        }
    }

    /// F0: donmuş μ'yı yeniden hesapla — §4.1b: günde en çok bir kez
    private func recomputeFrozenMean() async {
        let items = (try? repo.timeline()) ?? []
        var allVectors: [[Float]] = []
        for item in items {
            guard let emb = item.embedding, let vec = VectorStore.decode(emb) else { continue }
            allVectors.append(vec)
        }
        guard let mu = CorpusCentering.mean(vectors: allVectors) else { return }

        let info = EmbeddingService.currentModelInfo
        let count = allVectors.count
        do {
            try repo.saveEmbeddingMeta(model: info.model, revision: info.revision,
                                       totalVector: mu.map { $0 * Float(count) },
                                       count: count, frozenMu: mu)
        } catch {
            // μ hesaplanamadıysa mevcut μ kullanılır — güvenli
            print("[EnrichmentQueue] frozen μ tazelenemedi: \(error)")
        }
    }

    // MARK: F2: Topic sınıflandırma pipeline'ı (3 katman, kesinlik sırasıyla)
    private func assignTopics(_ item: inout Item, allVecs: [[Float]]) throws {
        guard let documentMean = CorpusCentering.mean(vectors: allVecs) else { return }
        let corpusMean = corpusMean() ?? [Float](repeating: 0, count: 512)

        // 1. Lexicon — kesin atama (§4.3 #1)
        let lexiconResults = TopicClassifier.classifyByLexicon(in: item.textContent ?? "")

        // 2. Prototip cosine — abstention'lı (§4.3 #2)
        let prototypeResults = TopicClassifier.classifyByPrototypes(
            text: item.textContent ?? "",
            vector: documentMean,
            corpusMean: corpusMean,
            topics: TaxonomyService.topicsWithPrototypes()
        )

        // 3. FoundationModels rafine (§4.3 #3) — async
        var combined = lexiconResults + prototypeResults
        if !combined.isEmpty {
            let availableTopics = (try? repo.topics()) ?? []
            combined = await FoundationModels.refine(
                text: item.textContent ?? "",
                currentTopics: combined,
                availableTopics: availableTopics
            )
        }

        // Sonuçları kaydet
        if !combined.isEmpty {
            let topicAssignments = combined.map { (topicId: $0.topicId, score: $0.score, source: $0.source) }
            try repo.saveItemTopics(itemId: item.id, topics: topicAssignments)
        }
    }

    private func corpusMean() -> [Float]? {
        let info = EmbeddingService.currentModelInfo
        if let meta = try? repo.loadEmbeddingMeta() {
            return meta.mu
        }
        return nil
    }
}
