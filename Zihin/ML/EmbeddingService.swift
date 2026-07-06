import Foundation
import CoreML
import NaturalLanguage

/// Metin -> vektör. Bundled multilingual model varsa onu (TR+EN aynı uzay),
/// yoksa Apple EN sentence embedding kullanır. Sorgu + item AYNI modeli kullanmalı;
/// model bundle'a eklendiyse hep o çalışır -> tutarlılık garantili.
enum EmbeddingService {
    static func embed(_ text: String) -> [Float]? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let v = MultilingualEmbedder.shared?.vector(for: clean) { return v }
        if let d = NLEmbedding.sentenceEmbedding(for: .english)?.vector(for: clean) {
            return d.map(Float.init)
        }
        return nil
    }
}

/// distiluse-base-multilingual-cased-v2 (512-dim). Dönüştürme script'i pooling+dense+
/// normalize'ı MODELE gömer (docs/SETUP_MAC.md §5) -> burada sadece tokenize + oku.
/// Bundle'da `Embedder.mlmodelc` + `vocab.txt` yoksa shared = nil (Apple EN fallback).
final class MultilingualEmbedder: @unchecked Sendable {
    static let shared = MultilingualEmbedder()

    private let model: MLModel
    private let vocab: [String: Int32]
    private let maxLen = 128
    private let clsID: Int32, sepID: Int32, unkID: Int32, padID: Int32

    private init?() {
        guard let mURL = Bundle.main.url(forResource: "Embedder", withExtension: "mlmodelc"),
              let vURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
              let m = try? MLModel(contentsOf: mURL),
              let vText = try? String(contentsOf: vURL, encoding: .utf8) else { return nil }
        model = m
        var v: [String: Int32] = [:]
        var i: Int32 = 0
        for line in vText.split(separator: "\n", omittingEmptySubsequences: false) {
            v[String(line)] = i; i += 1
        }
        vocab = v
        guard let cls = v["[CLS]"], let sep = v["[SEP]"],
              let unk = v["[UNK]"], let pad = v["[PAD]"] else { return nil }
        clsID = cls; sepID = sep; unkID = unk; padID = pad
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

    /// BERT WordPiece (cased): whitespace+noktalama böl, greedy longest-match, "##" devamı.
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
