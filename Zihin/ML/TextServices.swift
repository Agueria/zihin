import Foundation
import NaturalLanguage

// MARK: - Dil + NER

enum LanguageService {
    static func dominantLanguage(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(1000)))
        return r.dominantLanguage?.rawValue
    }

    /// Kişi / yer / organizasyon (brand etiketleme).
    static func namedEntities(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        var out = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType, options: opts) { tag, range in
            if let tag, wanted.contains(tag) { out.insert(String(text[range])) }
            return true
        }
        return Array(out)
    }

    /// v2 (§4.7): NLTagger(.lemma) gölge metni — `yazılımcı` ≡ `yazılım` aramada eşleşsin.
    static func lemmatize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var out: [String] = []
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lemma, options: opts) { tag, range in
            if let lemma = tag?.rawValue, !lemma.isEmpty { out.append(lemma.lowercased()) }
            else { out.append(text[range].lowercased()) }
            return true
        }
        return out.joined(separator: " ")
    }
}

// MARK: - Stopwords (TR + EN)

enum Stopwords {
    static let tr: Set<String> = [
        "acaba","ama","ancak","artık","aslında","az","bana","bazen","bazı","belki","ben","benim",
        "beri","bile","bir","biraz","biri","birkaç","birçok","biz","bize","bizim","böyle","bu",
        "buna","bunda","bundan","bunlar","bunu","bunun","burada","bütün","çok","çünkü","da","daha",
        "de","değil","demek","diğer","diye","dolayı","en","fakat","falan","gibi","göre","hala",
        "hangi","hatta","hem","henüz","hep","hepsi","her","herkes","hiç","için","içinde","ile",
        "ilgili","ise","işte","itibaren","kadar","karşı","kendi","kez","ki","kim","kimse","mi",
        "mı","mu","mü","nasıl","ne","neden","nerede","nereye","niye","niçin","o","olan","olarak",
        "oldu","olduğu","olmak","olması","olur","ona","ondan","onlar","onların","onu","onun",
        "orada","oysa","önce","ötürü","pek","rağmen","sadece","sanki","sen","senin","siz","sizin",
        "son","sonra","şey","şimdi","şu","şuna","şunu","tabi","tam","tüm","üzere","var","ve",
        "veya","ya","yani","yine","yok","zaten","zaman"]
    static let en: Set<String> = [
        "the","and","a","an","of","to","in","is","it","for","on","with","as","at","by","this",
        "that","or","be","are","from","but","not","you","your","we","can","was","were","will",
        "would","could","should","has","have","had","do","does","did","if","then","than","so",
        "no","yes","my","me","he","she","they","them","their","its","our","us","about","into",
        "over","after","before","between","out","up","down","just","also","more","most","some",
        "any","all","each","other","such","only","own","same","very","too","how","what","when",
        "where","which","who","why","there","here","because","while","during","again","once"]
    static let all: Set<String> = tr.union(en)
}

// MARK: - Keyword (RAKE-benzeri)

enum KeywordService {
    static func keywords(_ text: String, n: Int = 8) -> [String] {
        let lower = text.lowercased()
        var phrases: [[String]] = []
        var current: [String] = []
        for token in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(token)
            if Stopwords.all.contains(t) || t.count < 2 {
                if !current.isEmpty { phrases.append(current); current = [] }
            } else {
                current.append(t)
                if current.count >= 4 { phrases.append(current); current = [] } // aşırı uzun ifadeyi kes
            }
        }
        if !current.isEmpty { phrases.append(current) }

        var freq: [String: Int] = [:], degree: [String: Int] = [:]
        for p in phrases {
            for w in p { freq[w, default: 0] += 1; degree[w, default: 0] += p.count - 1 }
        }
        var wordScore: [String: Float] = [:]
        for (w, f) in freq { wordScore[w] = Float(degree[w, default: 0] + f) / Float(f) }

        var phraseScore: [(String, Float)] = phrases.map { p in
            (p.joined(separator: " "), p.reduce(Float(0)) { $0 + (wordScore[$1] ?? 0) })
        }
        var seen = Set<String>()
        phraseScore = phraseScore.filter { seen.insert($0.0).inserted }
        return phraseScore.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 }
    }
}

// MARK: - Extractive özet (TextRank)

enum SummaryService {
    /// En önemli `n` cümle, orijinal sırada.
    static func summarize(_ text: String, n: Int = 3) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > n else { return sentences.joined(separator: " ") }

        let vecs: [[Float]] = sentences.map { EmbeddingService.embed($0) ?? [] }
        let usable = vecs.allSatisfy { !$0.isEmpty }

        let c = sentences.count
        var sim = Array(repeating: Array(repeating: Float(0), count: c), count: c)
        for i in 0..<c {
            for j in (i+1)..<c {
                let s = usable ? VectorStore.cosine(vecs[i], vecs[j])
                               : tfCosine(sentences[i], sentences[j])
                sim[i][j] = s; sim[j][i] = s
            }
        }
        var rank = Array(repeating: Float(1) / Float(c), count: c)
        let damping: Float = 0.85
        for _ in 0..<30 {
            var next = Array(repeating: (1 - damping) / Float(c), count: c)
            for i in 0..<c {
                let outSum = sim[i].reduce(0, +)
                guard outSum > 0 else { continue }
                for j in 0..<c where i != j {
                    next[j] += damping * rank[i] * (sim[i][j] / outSum)
                }
            }
            rank = next
        }
        let top = rank.enumerated().sorted { $0.element > $1.element }
            .prefix(n).map { $0.offset }.sorted()
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
        func bag(_ s: String) -> [String: Float] {
            var d: [String: Float] = [:]
            for w in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
                let t = String(w)
                if Stopwords.all.contains(t) { continue }
                d[t, default: 0] += 1
            }
            return d
        }
        let x = bag(a), y = bag(b)
        var dot: Float = 0, nx: Float = 0, ny: Float = 0
        for k in Set(x.keys).union(y.keys) {
            let vx = x[k] ?? 0, vy = y[k] ?? 0
            dot += vx * vy; nx += vx * vx; ny += vy * vy
        }
        let den = nx.squareRoot() * ny.squareRoot()
        return den == 0 ? 0 : dot / den
    }
}
