import Foundation
import GRDB

/// Merkezlenmiş benzerlik (spec §2.4/§4.1b) — tasarımın merkezindeki bulgu.
/// Mean-pool'lanmış bağlamsal embedding'ler anizotropik; korpus ortalaması μ çıkarılınca
/// ayrışma 7.7×, dinamik aralık 5.4× artıyor. HAM cosine mutlak eşikle KULLANILMAZ.

/// Karşılaştırmalarda fiilen kullanılan donmuş μ. Okuma anında `v − μ` uygulanır.
struct CorpusMean: Sendable {
    let mu: [Float]
    func center(_ v: [Float]) -> [Float] {
        guard v.count == mu.count else { return v }
        var out = v
        for i in 0..<out.count { out[i] -= mu[i] }
        return out
    }
}

enum Centered {
    /// İki ham vektörü μ ile merkezleyip cosine döndürür.
    static func cosine(_ a: [Float], _ b: [Float], mu: [Float]) -> Float {
        let cm = CorpusMean(mu: mu)
        return VectorStore.cosine(cm.center(a), cm.center(b))
    }
}

/// μ mağazası: sürekli biriken toplam (Σv, count) + karşılaştırmalarda kullanılan DONMUŞ μ.
/// Ayrım şart (§4.1b): μ her notta kaysaydı space üyeliği ve graph kenarları titrerdi.
enum CenteringStore {
    static let dimension = 512
    static let blendK = 50                       // μ₀ harmanlama ağırlığı (soğuk başlangıç)
    private static let sumKey = "sum"
    private static let frozenKey = "frozen"
    private static let refreshDefaultsKey = "muFrozenRefreshedAt"

    // MARK: μ₀ bootstrap (Resources/mu0.bin — 512 float, ~2 KB)
    static func mu0() -> [Float] {
        guard let url = Bundle.main.url(forResource: "mu0", withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count == dimension * 4 else {
            return [Float](repeating: 0, count: dimension)     // güvenli: sıfır μ = ham cosine
        }
        return VectorStore.decode(data)
    }

    /// μ = (n·μ_user + k·μ₀)/(n+k) = (Σv + k·μ₀)/(n+k)  (§4.1b)
    static func blend(userSum: [Float], count: Int, mu0: [Float], k: Int = blendK) -> [Float] {
        guard count > 0, userSum.count == mu0.count else { return mu0 }
        let denom = Float(count + k)
        var out = [Float](repeating: 0, count: mu0.count)
        for i in 0..<out.count { out[i] = (userSum[i] + Float(k) * mu0[i]) / denom }
        return out
    }

    // MARK: Σv biriktir — her item'da çağrılır (§4.1b, "toplam her item'da güncellenir")
    static func runningAdd(_ v: [Float], model: String, revision: Int, _ db: Database) throws {
        guard v.count == dimension else { return }
        let existing = try EmbeddingMeta.fetchOne(db, key: sumKey)
        // Model/revision değişmişse toplam sıfırlanır (§4.1a — farklı model uzayı karışmasın)
        let reset = existing?.model != model || existing?.revision != revision
        var sum = (!reset ? existing?.vector.map(VectorStore.decode) : nil)
            ?? [Float](repeating: 0, count: dimension)
        if sum.count != dimension { sum = [Float](repeating: 0, count: dimension) }
        for i in 0..<dimension { sum[i] += v[i] }
        let count = (reset ? 0 : (existing?.count ?? 0)) + 1
        var row = EmbeddingMeta(key: sumKey, vector: VectorStore.encode(sum),
                                count: count, model: model, revision: revision)
        try row.save(db)
    }

    // MARK: Karşılaştırmalarda kullanılan donmuş μ
    static func frozenMu(_ db: Database) throws -> CorpusMean {
        if let frozen = try EmbeddingMeta.fetchOne(db, key: frozenKey),
           let vec = frozen.vector.map(VectorStore.decode), vec.count == dimension {
            return CorpusMean(mu: vec)
        }
        // Henüz donmamışsa: mevcut toplamdan (yoksa μ₀'dan) hesapla
        return CorpusMean(mu: try computeBlendedMu(db))
    }

    /// Donmuş μ'yu günde en çok bir kez (veya reindex'te force) tazele (§4.1b/§6).
    @discardableResult
    static func refreshFrozenMuIfNeeded(_ db: Database, force: Bool = false,
                                        now: Date = Date()) throws -> Bool {
        let defaults = UserDefaults(suiteName: DatabaseManager.appGroupID)
        let last = defaults?.object(forKey: refreshDefaultsKey) as? Date
        let stale = last == nil || now.timeIntervalSince(last!) >= 86_400
        guard force || stale else { return false }

        let mu = try computeBlendedMu(db)
        let sumRow = try EmbeddingMeta.fetchOne(db, key: sumKey)
        var frozen = EmbeddingMeta(key: frozenKey, vector: VectorStore.encode(mu),
                                   count: sumRow?.count, model: sumRow?.model,
                                   revision: sumRow?.revision)
        try frozen.save(db)
        defaults?.set(now, forKey: refreshDefaultsKey)
        return true
    }

    private static func computeBlendedMu(_ db: Database) throws -> [Float] {
        let base = mu0()
        guard let sumRow = try EmbeddingMeta.fetchOne(db, key: sumKey),
              let sum = sumRow.vector.map(VectorStore.decode),
              let count = sumRow.count, count > 0 else { return base }
        return blend(userSum: sum, count: count, mu0: base)
    }
}
