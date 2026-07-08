import Foundation
import NaturalLanguage

// v2 (spec §4.1) — tek `EmbeddingService.embed` yerine sağlayıcı protokolü.
// Varsayılan: NLContextualEmbedding (0 MB, Türkçe destekli, §2.3). Opsiyonel: SentenceProvider (F5).
// Her iki sağlayıcı da 512 boyutlu; model kimliği kayıtta tutulur (§4.1a — sessiz bozulma yok).

protocol EmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var revision: Int { get }
    var dimension: Int { get }
    /// Metni parçalayıp CHUNK BAŞINA bir vektör döndürür (§4.1c). Model inmemişse nil.
    func embed(_ text: String) -> [[Float]]?
}

/// NLContextualEmbedding tabanlı varsayılan sağlayıcı. Değer tipi; ağır motoru paylaşılan
/// `ContextualEngine`'e devreder (NLContextualEmbedding Sendable değil).
struct ContextualProvider: EmbeddingProvider {
    var modelIdentifier: String { ContextualEngine.shared.modelIdentifier }
    var revision: Int { ContextualEngine.shared.revision }
    var dimension: Int { 512 }
    func embed(_ text: String) -> [[Float]]? { ContextualEngine.shared.embedChunks(text) }
    /// Asset talep üzerine iner (§2.3/§6). İndirilene kadar embed nil döner → yalnız FTS5.
    func prepareAssets() async { await ContextualEngine.shared.requestAssets() }
}

/// NLContextualEmbedding sarmalayıcısı. Kilit altında; token vektörlerini chunk başına
/// mean-pool'lar. NOT: kesin async asset API'si Mac'te doğrulanmalı.
final class ContextualEngine: @unchecked Sendable {
    static let shared = ContextualEngine()
    private let lock = NSLock()
    private let embedding: NLContextualEmbedding?
    private var loaded = false
    let modelIdentifier: String
    let revision: Int

    private init() {
        let e = NLContextualEmbedding(script: .latin)
        embedding = e
        modelIdentifier = e?.modelIdentifier ?? "NLContextualEmbedding.latin"
        revision = e?.revision ?? 1
    }

    func requestAssets() async {
        guard let e = embedding else { return }
        if !e.hasAvailableAssets { _ = try? await e.requestAssets() }
        lock.lock(); defer { lock.unlock() }
        if !loaded { loaded = ((try? e.load()) != nil) }
    }

    func embedChunks(_ text: String) -> [[Float]]? {
        let chunks = Chunker.chunks(text)
        guard !chunks.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = embedding else { return nil }
        if !loaded { guard (try? e.load()) != nil else { return nil }; loaded = true }

        var out: [[Float]] = []
        let dim = e.dimension
        for chunk in chunks {
            guard let result = try? e.embeddingResult(for: chunk, language: nil) else { continue }
            var acc = [Float](repeating: 0, count: dim)
            var n = 0
            result.enumerateTokenVectors(in: chunk.startIndex..<chunk.endIndex) { vector, _ in
                if vector.count == dim {
                    for i in 0..<dim { acc[i] += Float(vector[i]) }
                    n += 1
                }
                return true
            }
            if n > 0 {
                for i in 0..<dim { acc[i] /= Float(n) }
                out.append(acc)
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Aktif sağlayıcıyı tutar, chunking + doküman vektörü + model damgalamasını yönetir (§4.1).
actor EmbeddingCoordinator {
    static let shared = EmbeddingCoordinator()
    private(set) var active: any EmbeddingProvider = ContextualProvider()

    func setActive(_ provider: any EmbeddingProvider) { active = provider }

    /// Asset'leri hazırlar (arka planda; inene kadar embed nil).
    func prepare() async {
        if let c = active as? ContextualProvider { await c.prepareAssets() }
    }

    /// Doküman vektörü (chunk ortalaması) + chunk vektörleri (arama max-pool için ayrı saklanır).
    func embedDocument(_ text: String) -> (doc: [Float], chunks: [[Float]])? {
        guard let chunks = active.embed(text), !chunks.isEmpty else { return nil }
        return (Pooling.meanPool(chunks), chunks)
    }

    /// Item'a aktif modelin kimliğini bas (§4.1a) — uyuşmazlık reindex tetikler.
    func stamp(_ item: inout Item) {
        item.embeddingModel = active.modelIdentifier
        item.embeddingRevision = active.revision
    }

    var modelIdentifier: String { active.modelIdentifier }
    var revision: Int { active.revision }
}
