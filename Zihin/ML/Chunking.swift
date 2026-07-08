import Foundation

/// Uzun metni ~200 token'lık pencerelere böler (spec §2.6/§4.1c).
/// NLContextualEmbedding 256 token'da kırpıyor; parçalama zorunlu.
/// Token yaklaşımı: boşlukla ayrılmış kelime ≈ 1 token (Latince script için yeterli).
enum Chunker {
    static func chunks(_ text: String, targetTokens: Int = 200, hardCap: Int = 240) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let words = clean.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > targetTokens else { return [clean] }

        var out: [String] = []
        var i = 0
        let window = min(targetTokens, hardCap)
        while i < words.count {
            let end = min(i + window, words.count)
            out.append(words[i..<end].joined(separator: " "))
            i = end
        }
        return out
    }
}

/// Vektör havuzlama (spec §4.1c). Arama: chunk max-pool; konu/graph: doküman ortalaması.
enum Pooling {
    /// Eleman bazında maksimum — pasaj erişiminin standardı.
    static func maxPool(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first, !first.isEmpty else { return [] }
        var out = first
        for v in vs.dropFirst() where v.count == out.count {
            for i in 0..<out.count { out[i] = max(out[i], v[i]) }
        }
        return out
    }

    /// Eleman bazında ortalama — doküman düzeyi temsil.
    static func meanPool(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first, !first.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: first.count)
        var n = 0
        for v in vs where v.count == out.count {
            for i in 0..<out.count { out[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return [] }
        for i in 0..<out.count { out[i] /= Float(n) }
        return out
    }
}
