import Foundation
import NaturalLanguage

// MARK: - KeywordKind (F2: keyword türlerini ayırır)
enum KeywordKind: String, Sendable {
    case topic, entity, color, keyword
}

// MARK: - AI Lexicon (F2: kesinlikle AI-related eşleşme)
enum AILexicon {
    /// {keyword → topicId} eşleşme tablosu — küratörlü
    static let mapping: [String: String] = [
        "opus": "tech-ai-lang-models",
        "claude": "tech-ai-lang-models",
        "gpt": "tech-ai-lang-models",
        "gpt-4": "tech-ai-lang-models",
        "gpt-3.5": "tech-ai-lang-models",
        "gpt-4o": "tech-ai-lang-models",
        "llm": "tech-ai-lang-models",
        "large language model": "tech-ai-lang-models",
        "prompt": "tech-ai-lang-models",
        "prompt engineering": "tech-ai-lang-models",
        "embedding": "tech-ai-nlp",
        "embedder": "tech-ai-nlp",
        "fine-tune": "tech-ai-ml",
        "fine tuning": "tech-ai-ml",
        "fine-tuning": "tech-ai-ml",
        "transformer": "tech-ai-lang-models",
        "attention": "tech-ai-lang-models",
        "tokenizer": "tech-ai-nlp",
        "token": "tech-ai-lang-models",
        "ml": "tech-ai-ml",
        "machine learning": "tech-ai-ml",
        "deep learning": "tech-ai-ml",
        "neural network": "tech-ai-ml",
        "openai": "tech-ai-lang-models",
        "anthropic": "tech-ai-lang-models",
        "hugging face": "tech-ai-ml",
        "huggingface": "tech-ai-ml",
        "mlx": "tech-ai-ml",
        "coreml": "tech-ai-ml",
        "onnx": "tech-ai-ml",
        "rag": "tech-ai-llm-apps",
        "vector database": "tech-ai-llm-apps",
        "chroma": "tech-ai-llm-apps",
        "pinecone": "tech-ai-llm-apps",
        "milvus": "tech-ai-llm-apps",
        "autonomous agent": "tech-ai-llm-apps",
        "agentic": "tech-ai-llm-apps",
        "computer vision": "tech-ai-vision",
        "image recognition": "tech-ai-vision",
        "object detection": "tech-ai-vision",
        "generative": "tech-ai-lang-models",
        "diffusion": "tech-ai-vision",
        "stable diffusion": "tech-ai-vision",
    ]

    /// Belirli bir kelime AI-related mı?
    static func isAI(keyword: String) -> Bool {
        mapping[keyword.lowercased()] != nil
    }

    /// AI-related topic ID'si
    static func aiTopicId(keyword: String) -> String? {
        mapping[keyword.lowercased()]
    }

    /// Metinde AI-related kelimeler bul
    static func detectAITokens(in text: String) -> [String] {
        let lower = text.lowercased()
        return mapping.keys.filter { lower.contains($0) }
    }
}

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

    /// F4: Lemma çıkarma (NLTagger .lemma)
    static func lemma(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tagger = NLTagger(tagScheme: .lemma)
        tagger.string = text
        tagger.locale = Locale(identifier: "tr_TR")
        var result = ""
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lemma, options: []) { tag, _ in
            if let tag = tag {
                result.append(tag.rawValue)
            } else {
                result.append(" ")
            }
            return true
        }
        return result
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

// MARK: - Topic Classifier (F2: prototip + abstention, §4.3)
struct TopicClassification: Sendable {
    let topicId: String
    let name: String
    let score: Double
    let margin: Double       // en yakın rakip ile fark
    let source: String       // lexicon|embedding|llm
}

enum TopicClassifier {
    /// Eşik değerleri — F0 kapısında golden set ile kalibre edilir
    struct Thresholds: Sendable {
        var topicThreshold: Double = 0.05   // τ_topic
        var marginThreshold: Double = 0.05  // δ
    }

    /// Lexicon ile kesin atama (ilk katman, §4.3 #1)
    static func classifyByLexicon(in text: String) -> [TopicClassification] {
        let detected = AILexicon.detectAITokens(in: text)
        return detected.compactMap { kw in
            guard let topicId = AILexicon.aiTopicId(keyword: kw) else { return nil }
            return TopicClassification(topicId: topicId, name: "", score: 1.0, margin: 1.0, source: "lexicon")
        }
    }

    /// Prototip cosine ile konu atama (ikinci katman, §4.3 #2)
    ///Abstention: skor < τ veya margin < δ ise hiçbir etiket atanmaz.
    static func classifyByPrototypes(
        text: String,
        vector: [Float],
        corpusMean: [Float],
        topics: [(id: String, name: String, prototypes: [[Float]])],
        thresholds: Thresholds = Thresholds()
    ) -> [TopicClassification] {
        let centered = CorpusCentering.center(vector: vector, mean: corpusMean) ?? vector
        let centeredProto = topics.map { topic in
            // Prototip merkezi = ortalaması
            var protoCenter = [Float](repeating: 0, count: topic.prototypes[0].count)
            for p in topic.prototypes {
                let c = CorpusCentering.center(vector: p, mean: corpusMean) ?? p
                for i in 0..<protoCenter.count { protoCenter[i] += c[i] }
            }
            let n = Float(topic.prototypes.count)
            for i in 0..<protoCenter.count { protoCenter[i] /= n }
            return (topic: topic, center: protoCenter)
        }

        var results: [TopicClassification] = []
        var scores: [Double] = []

        for tp in centeredProto {
            guard let s = CorpusCentering.cosine(centered, tp.center) else { continue }
            scores.append(s)
        }

        for i in 0..<centeredProto.count {
            let s = scores[i]
            guard s >= thresholds.topicThreshold else { continue }

            // Margin: en yakın rakip ile fark
            let others = scores.enumerated()
                .filter { $0.offset != i }
                .map { $0.element }
            let bestOther = others.max() ?? -1
            let margin = s - bestOther

            guard margin >= thresholds.marginThreshold else { continue }
            results.append(TopicClassification(
                topicId: centeredProto[i].topic.id,
                name: centeredProto[i].topic.name,
                score: s,
                margin: margin,
                source: "embedding"
            ))
        }

        return results
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
