import Foundation
import NaturalLanguage
import UIKit

// MARK: - EmbeddingProvider Protocol (F0: tek fonksiyondan protokole)
protocol EmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var revision: Int { get }
    var dimension: Int { get }
    func embed(_ text: String) -> [[Float]]?     // chunk başına bir vektör
}

/// NLContextualEmbedding — Türkçe destekli, 512 boyut, 0 MB bundle maliyeti
/// (§2.3: Turkish supported, assets downloaded on demand)
final class ContextualProvider: EmbeddingProvider, @unchecked Sendable {
    static let defaultIdentifier = "5C45D94E-BAB4-4927-94B6-8B5745C46289"
    static let dimension = 512
    static let revision = 1

    let modelIdentifier: String
    let revision: Int
    let dimension: Int

    private var contextualEmbedding: NLContextualEmbedding?
    private let lock = NSLock()

    init(modelIdentifier: String = Self.defaultIdentifier) {
        self.modelIdentifier = modelIdentifier
        self.revision = Self.revision
        self.dimension = Self.dimension
    }

    func embed(_ text: String) -> [[Float]]? {
        guard let embedding = getOrCreateContextualEmbedding() else { return nil }
        let chunks = Chunker.chunk(text)
        guard !chunks.isEmpty else { return nil }

        var results: [[Float]] = []
        for chunk in chunks {
            if let vec = embedding.vector(for: chunk) {
                results.append(vec)
            }
        }
        return results.isEmpty ? nil : results
    }

    /// Tüm varlıklar indirilene kadar bekler (assets talep üzerine gelir).
    /// İndirme başarısız olursa yalnızca FTS5 ile çalışmaya devam eder.
    func ensureAssets() async {
        guard let ce = getOrCreateContextualEmbedding() else { return }
        guard !ce.hasAvailableAssets else { return }
        await withCheckedContinuation { cont in
            ce.requestAssets { available in
                cont.resume()
            }
        }
    }

    private func getOrCreateContextualEmbedding() -> NLContextualEmbedding? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = contextualEmbedding { return existing }

        let ce = NLContextualEmbedding(language: .init(identifier: .turkish))
        // Verify model is available
        guard ce.hasAvailableAssets else {
            contextualEmbedding = ce
            return ce
        }
        contextualEmbedding = ce
        return ce
    }
}

/// MultilingualEmbedder — eski model (opsiyonel indirme, §4.1)
/// Bundle'da yoksa diskten App Group'dan yükler.
final class MultilingualEmbedder: EmbeddingProvider, @unchecked Sendable {
    static let defaultIdentifier = "multilingual-v2"
    static let dimension = 512
    static let revision = 1

    let modelIdentifier: String
    let revision: Int
    let dimension: Int

    private let model: MLModel
    private let vocab: [String: Int32]
    private let maxLen = 128
    private let clsID: Int32, sepID: Int32, unkID: Int32, padID: Int32

    private init?(modelURL: URL) {
        guard let vURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
              let vText = try? String(contentsOf: vURL, encoding: .utf8) else { return nil }
        model = try! MLModel(contentsOf: modelURL)
        var v: [String: Int32] = [:]
        var i: Int32 = 0
        for line in vText.split(separator: "\n", omittingEmptySubsequences: false) {
            v[String(line)] = i; i += 1
        }
        vocab = v
        guard let cls = v["[CLS]"], let sep = v["[SEP]"],
              let unk = v["[UNK]"], let pad = v["[PAD]"] else { return nil }
        clsID = cls; sepID = sep; unkID = unk; padID = pad
        self.modelIdentifier = Self.defaultIdentifier
        self.revision = Self.revision
        self.dimension = Self.dimension
    }

    static func createIfNeeded() -> MultilingualEmbedder? {
        // Check bundle first
        if let mURL = Bundle.main.url(forResource: "Embedder", withExtension: "mlmodelc") {
            return MultilingualEmbedder(modelURL: mURL)
        }
        // Check App Group (downloaded model)
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.app.zihin") else { return nil }
        let modelURL = container.appendingPathComponent("Embedder.mlmodelc")
        if FileManager.default.fileExists(atPath: modelURL.path) {
            return MultilingualEmbedder(modelURL: modelURL)
        }
        return nil
    }

    func vector(for text: String) -> [Float]? {
        let ids = tokenize(text)
        guard ids.count > 2,
              let inputIDs = try? MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
        else { return nil }
        for i in 0..<maxLen {
            inputIDs[i] = NSNumber(value: i < ids.count ? ids[i] : padID)
            mask[i] = NSNumber(value: i < ids.count ? 1 : 0)
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                  "input_ids": MLFeatureValue(multiArray: inputIDs),
                  "attention_mask": MLFeatureValue(multiArray: mask)]),
              let out = try? model.prediction(from: provider),
              let name = out.featureNames.first,
              let arr = out.featureValue(for: name)?.multiArrayValue
        else { return nil }
        let n = arr.count
        var vec = [Float](repeating: 0, count: n)
        for i in 0..<n { vec[i] = arr[i].floatValue }
        return vec
    }

    func embed(_ text: String) -> [[Float]]? {
        vector(for: text).map { [$0] }
    }

    private func tokenize(_ text: String) -> [Int32] {
        var words: [String] = []
        var current = ""
        for ch in text.prefix(2000) {
            if ch.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isPunctuation || ch.isSymbol {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }

        var ids: [Int32] = [clsID]
        for word in words {
            if ids.count >= maxLen - 1 { break }
            ids.append(contentsOf: wordPiece(word))
        }
        ids = Array(ids.prefix(maxLen - 1))
        ids.append(sepID)
        return ids
    }

    private func wordPiece(_ word: String) -> [Int32] {
        if let id = vocab[word] { return [id] }
        var out: [Int32] = []
        let chars = Array(word)
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32?
            while end > start {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unkID] }
            out.append(id)
            start = end
        }
        return out
    }
}

// MARK: - Chunking (F0: §2.6 — 256 token sınırı)
enum Chunker {
    /// ~200 token'lık (≈800 char) pencereler, 50 token overlap
    static func chunk(_ text: String, chunkSize: Int = 200, overlap: Int = 50) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let charsPerToken = 4
        let chunkChars = chunkSize * charsPerToken
        let overlapChars = overlap * charsPerToken

        // Bölünüm: cümle sınırlarını koru
        var sentences: [String] = []
        var current = ""
        for ch in clean {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }

        guard !sentences.isEmpty else {
            // Cümle yoksa direkt parçala
            return splitByChars(clean, size: chunkChars, overlap: overlapChars)
        }

        var chunks: [String] = []
        var accumulator = ""
        for sentence in sentences {
            if (accumulator + " " + sentence).count > chunkChars && !accumulator.isEmpty {
                chunks.append(accumulator.trimmingCharacters(in: .whitespaces))
                // Son cümleyi bırak ki overlap sağlansın
                if accumulator.components(separatedBy: " ").count > 1 {
                    let lastSentence = accumulator.components(separatedBy: " ").dropLast().joined(separator: " ")
                    accumulator = lastSentence
                } else {
                    accumulator = sentence
                }
            } else {
                accumulator = accumulator.isEmpty ? sentence : "\(accumulator) \(sentence)"
            }
        }
        if !accumulator.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(accumulator.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }

    private static func splitByChars(_ text: String, size: Int, overlap: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        var chunks: [String] = []
        var start = 0
        while start < chars.count {
            let end = min(start + size, chars.count)
            chunks.append(String(chars[start..<end]))
            start = end - overlap
            if start >= chars.count { break }
        }
        return chunks
    }
}

// MARK: - Corpus Mean & Centering (F0: §2.4)
enum CorpusCentering {
    /// Korpus ortalamasını hesapla
    static func mean(vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        let dim = vectors[0].count
        var sum = [Float](repeating: 0, count: dim)
        for v in vectors {
            guard v.count == dim else { return nil }
            for i in 0..<dim { sum[i] += v[i] }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    /// Merkezi çıkar: l2(v - μ) — anizotropiyi kırar
    static func center(vector: [Float], mean: [Float]) -> [Float]? {
        guard vector.count == mean.count else { return nil }
        return zip(vector, mean).map { $0 - $1 }
    }

    /// Merkezlenmiş cosine benzerliği
    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let dot = zip(a, b).reduce(0) { $0 + Double($1.0 * $1.1) }
        let magA = sqrt(Double(a.map { Double($0 * $0) }.reduce(0, +)))
        let magB = sqrt(Double(b.map { Double($0 * $0) }.reduce(0, +)))
        guard magA > 0 && magB > 0 else { return nil }
        return dot / (magA * magB)
    }

    /// Bootstrap μ₀ (generic Turkish) — bundle'da 512 float = 2 KB
    /// Soğuk başlangıç için n<50 kullanıcılarda güvenli
    static func blendWithBootstrap(userMu: [Float], bootstrapMu: [Float], userCount: Int, bootstrapK: Int = 50) -> [Float]? {
        guard userMu.count == bootstrapMu.count else { return nil }
        let n = Double(userCount)
        let k = Double(bootstrapK)
        let total = n + k
        return zip(userMu, bootstrapMu).map {
            Float(($0 * n + $1 * k) / total)
        }
    }
}

// MARK: - Default Embedding Service (F0)
enum EmbeddingService {
    /// Default provider: ContextualProvider
    static let provider: EmbeddingProvider = ContextualProvider()

    /// Tüm item'ların embedding model bilgisini döndür
    static var currentModelInfo: (model: String, revision: Int, dimension: Int) {
        (provider.modelIdentifier, provider.revision, provider.dimension)
    }
}

// MARK: - Optional model download (F5)

enum AdvancedModelDownloader: Sendable {
    /// ~80 MB model indirme — App Group'a yaz, SHA-256 doğrula
    /// Yarım kalan indirme çökmeye yol açmaz.
    static func downloadIfNeeded() async {
        // İndirme durumu App Group'ta saklanır
        guard !UserDefaults(suiteName: "group.app.zihin")?.bool(forKey: "advancedModelDownloaded") == true else { return }

        // Bu URL gerçek deploy'da değiştirilecek
        let modelURL = URL(string: "https://example.com/Embedder.mlmodelc.zip")!
        let vocabURL = URL(string: "https://example.com/vocab.txt")!

        do {
            // 1) Geçici dizine indir
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("zihin_model_download")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            let (_, modelResponse) = try await URLSession.shared.download(from: modelURL)
            let (_, vocabResponse) = try await URLSession.shared.download(from: vocabURL)

            // 2) SHA-256 doğrula
            let modelSHA = try sha256(from: modelResponse)
            let vocabSHA = try sha256(from: vocabResponse)
            // Gerçek SHA değerler deploy'da gelecek
            let expectedModelSHA = "expected-model-sha-here"
            let expectedVocabSHA = "expected-vocab-sha-here"
            guard modelSHA == expectedModelSHA, vocabSHA == expectedVocabSHA else {
                throw DownloadError.shaMismatch
            }

            // 3) App Group'a taşı
            guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.app.zihin") else {
                throw DownloadError.noContainer
            }
            let destDir = container.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            try FileManager.default.moveItem(at: modelResponse, to: destDir.appendingPathComponent("Embedder.mlmodelc"))
            try FileManager.default.moveItem(at: vocabResponse, to: destDir.appendingPathComponent("vocab.txt"))

            // 4) Başarı bayrağı
            UserDefaults(suiteName: "group.app.zihin")?.set(true, forKey: "advancedModelDownloaded")

            // 5) Model değişti → reindex tetikle
            // EnrichmentQueue bunu algılayacak (model mismatch)

        } catch {
            // Yarım kalan geçici dosyaları temizle
            try? FileManager.default.removeItem(at: tmpDir)
            print("[AdvancedModelDownloader] İndirme başarısız: \(error)")
        }
    }

    private enum DownloadError: Error {
        case shaMismatch
        case noContainer
    }

    private static func sha256(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto
