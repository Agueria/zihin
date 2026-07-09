import Foundation
import GRDB

// MARK: - Sorgu ayrıştırma (renk + tarih sinyalleri, F4: topic/type/in:space)

struct ParsedQuery: Sendable {
    var cleaned: String
    var colors: [String]
    var dateRange: (start: Date, end: Date)?
    var topics: [String]
    var types: [String]
    var inSpace: String?
}

enum SearchQueryParser {
    static func parse(_ query: String) -> ParsedQuery {
        var tokens = query.lowercased().split(separator: " ").map(String.init)
        let colorNames = Set(NamedColors.palette.map { $0.name })
        let colors = tokens.filter { colorNames.contains($0) }
        tokens.removeAll { colorNames.contains($0) }

        var range: (Date, Date)?
        let cal = Calendar.current
        let now = Date()
        func consume(_ words: [String], _ r: (Date, Date)) {
            if tokens.contains(where: { words.contains($0) }) {
                range = r
                tokens.removeAll { words.contains($0) }
            }
        }
        consume(["bugün", "today"], (cal.startOfDay(for: now), now))
        consume(["dün", "yesterday"],
                (cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!,
                 cal.startOfDay(for: now)))
        consume(["hafta", "week"],
                (cal.date(byAdding: .day, value: -7, to: now)!, now))

        // F4: topic:ai, type:note, in:space-name
        var topics: [String] = []
        var types: [String] = []
        var inSpace: String?

        var remainingTokens: [String] = []
        for token in tokens {
            if token.hasPrefix("topic:") {
                topics.append(String(token.dropFirst(6)))
            } else if token.hasPrefix("type:") {
                types.append(String(token.dropFirst(5)))
            } else if token.hasPrefix("in:") {
                inSpace = String(token.dropFirst(3))
            } else {
                remainingTokens.append(token)
            }
        }
        tokens = remainingTokens

        return ParsedQuery(cleaned: tokens.joined(separator: " "), colors: colors, dateRange: range,
                           topics: topics, types: types, inSpace: inSpace)
    }
}

// MARK: - Search (F4: lemma, BM25 ağırlıkları, MMR, filtreler)

struct SearchResult: Sendable {
    let items: [Item]
    let scores: [String: Double]
}

/// F0: korpus ortalaması (μ) cache'i — §4.7 #8
private actor CorpusMeanCache {
    private var cached: [Float]?
    private var model: String?
    private var revision: Int?

    func get(model: String, revision: Int) -> [Float]? {
        guard model == model, revision == revision, let mu = cached else { return nil }
        return mu
    }

    func set(_ mu: [Float], model: String, revision: Int) {
        self.cached = mu
        self.model = model
        self.revision = revision
    }
}

enum SearchService: Sendable {
    let db = DatabaseManager.shared.dbPool
    private let repo = ItemRepository()
    private let meanCache = CorpusMeanCache()

    // MARK: F0: corpus mean yükle (donmuş μ)
    func corpusMean() -> [Float]? {
        let info = EmbeddingService.currentModelInfo
        if let cached = try? meanCache.get(model: info.model, revision: info.revision) {
            return cached
        }
        if let meta = try? repo.loadEmbeddingMeta() {
            // μ donmuş hali zaten
            try? meanCache.set(meta.mu, model: meta.model, revision: meta.revision)
            return meta.mu
        }
        return nil
    }

    // MARK: F1: matches() — boolean üyelik (precision odaklı)
    /// Space üyeliği için: cosine ≥ threshold VE excluded değil
    /// §4.4: matches ≠ search — matches kesin üyelik, search sıralı recall
    func matches(_ space: Space, item: Item, corpusMean: [Float]) -> Bool {
        guard space.threshold != nil, let embedding = item.embedding,
              let vec = VectorStore.decode(embedding),
              !item.forgotten else { return false }

        // Merkezle
        let centered = CorpusCentering.center(vector: vec, mean: corpusMean) ?? vec

        // F1: item vektörünü space centroid'i ile karşılaştır
        // Space centroid = space içindeki tüm item'ların merkezlenmiş ortalaması
        guard let centroid = spaceCentroid(for: space, corpusMean: corpusMean) else {
            // Centroid yoksa (yeni space), corpus mean'e göre değerlendir
            guard let sim = CorpusCentering.cosine(centered, corpusMean) else { return false }
            return sim >= (space.threshold ?? 0.05)
        }

        let sim = CorpusCentering.cosine(centered, centroid) ?? 0
        return sim >= (space.threshold ?? 0.05)
    }

    /// Space centroid'i hesapla — space içindeki tüm item'ların merkezlenmiş ortalaması
    private func spaceCentroid(for space: Space, corpusMean: [Float]) -> [Float]? {
        guard let items = try? repo.items(ids: spaceMemberIds(space)) else { return nil }
        guard !items.isEmpty else { return nil }

        var vectors: [[Float]] = []
        for item in items {
            guard let emb = item.embedding, let vec = VectorStore.decode(emb) else { continue }
            if let c = CorpusCentering.center(vector: vec, mean: corpusMean) {
                vectors.append(c)
            }
        }
        return CorpusCentering.mean(vectors: vectors)
    }

    private func spaceMemberIds(_ space: Space) -> [String] {
        try? db.read { d in
            try String.fetchAll(d, sql: """
                SELECT itemId FROM item_space
                WHERE spaceId = ? AND excluded = 0
                """, arguments: [space.id])
        } ?? []
    }

    // MARK: F4: search — recall odaklı, sıralı, eşiksiz
    func search(_ rawQuery: String, limit: Int = 50) async -> [Item] {
        let q = SearchQueryParser.parse(rawQuery)
        let cm = corpusMean()

        let ftsRanked = (try? ftsSearch(q.cleaned)) ?? []
        let vecRanked = vectorSearch(q.cleaned, corpusMean: cm)

        // Reciprocal Rank Fusion
        var score: [String: Double] = [:]
        let k = 60.0
        for (i, id) in ftsRanked.enumerated() { score[id, default: 0] += 1.0 / (k + Double(i)) }
        for (i, id) in vecRanked.enumerated() { score[id, default: 0] += 1.0 / (k + Double(i)) }

        var items = (try? repo.items(ids: Array(score.keys))) ?? []

        // Yalnız renk/tarih sorgusu -> doğrudan filtreli tam liste
        if q.cleaned.trimmingCharacters(in: .whitespaces).isEmpty,
           !q.colors.isEmpty || q.dateRange != nil {
            items = (try? repo.timeline()) ?? []
        }
        if !q.colors.isEmpty {
            items = items.filter { !Set($0.colors).isDisjoint(with: q.colors) }
        }
        if let r = q.dateRange {
            items = items.filter { $0.createdAt >= r.start && $0.createdAt <= r.end }
        }
        // F4: topic filtre — topicId prefix veya isim eşleşmesi (topic:ai → tech-ai-*)
        if !q.topics.isEmpty {
            items = items.filter { item in
                guard let itemTopics = try? repo.topicsForItem(itemId: item.id) else { return false }
                return itemTopics.contains { t in
                    q.topics.contains { needle in
                        t.topicId.lowercased().contains(needle)
                            || t.name.lowercased().contains(needle)
                    }
                }
            }
        }
        // F4: type filtre
        if !q.types.isEmpty {
            items = items.filter { q.types.contains($0.type.rawValue) }
        }
        // F4: in:space filtre
        if let spaceName = q.inSpace {
            items = items.filter { item in
                (try? repo.spaces()).contains { s in
                    s.name.lowercased() == spaceName &&
                    (try? repo.db.read { d in
                        ItemSpace.fetchOne(d, sql: "SELECT * FROM item_space WHERE itemId=? AND spaceId=? AND excluded=0",
                                          arguments: [item.id, s.id]) != nil
                    }) == true
                }
            }
        }

        return items
            .filter { !$0.forgotten }
            .sorted { (score[$0.id] ?? 0) > (score[$1.id] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    /// MMR ile çeşitlendirilmiş arama (F4: §4.7 #5)
    func searchMMR(_ rawQuery: String, limit: Int = 50, lambda: Double = 0.7) async -> [Item] {
        let q = SearchQueryParser.parse(rawQuery)
        let allResults = await search(rawQuery, limit: limit * 3)
        let cm = corpusMean()

        guard !allResults.items.isEmpty else { return [] }

        // Seçilmiş sonuçlar kümesi
        var selected: [String] = []
        var candidateScores: [String: Double] = [:]

        for item in allResults.items {
            candidateScores[item.id] = (try? repo.item(id: item.id)).map { score[$0.id] ?? 0 }
        }

        // İlk sonuç
        guard let first = allResults.items.first else { return [] }
        selected.append(first.id)

        // F0: query vektörünü merkezle
        let queryVec = EmbeddingService.embed(q.cleaned)
        let centeredQ = queryVec.flatMap { CorpusCentering.center(vector: $0, mean: cm ?? []) }

        while selected.count < limit && candidateScores.count > selected.count {
            var bestId: String?
            var bestScore: Double?

            for (id, relevance) in candidateScores {
                guard !selected.contains(id) else { continue }

                let maxSimilarity = selected.compactMap { sid in
                    guard let sv = (try? repo.db.read { d in
                        Item.fetchOne(d, key: sid)?.embedding
                    }), let svf = VectorStore.decode(sv) else { return nil }
                    // F0: item vektörünü de merkezle
                    let centeredI = CorpusCentering.center(vector: svf, mean: cm ?? []) ?? svf
                    return CorpusCentering.cosine(centeredI, centeredQ ?? []).map { Double($0) } ?? 0
                }.max() ?? 0

                let mmr = lambda * relevance - (1 - lambda) * maxSimilarity
                if bestScore == nil || mmr > bestScore! {
                    bestId = id
                    bestScore = mmr
                }
            }

            if let id = bestId {
                selected.append(id)
            } else { break }
        }

        let finalItems = (try? repo.items(ids: selected)) ?? []
        return finalItems.sorted { a, b in
            selected.firstIndex(of: a.id)! < selected.firstIndex(of: b.id)!
        }
    }

    // MARK: Same Vibe
    func similarImages(to itemId: String, limit: Int = 12) -> [Item] {
        guard let target = try? repo.item(id: itemId),
              let tfp = target.featurePrint else { return [] }
        let ranked = ((try? repo.allFeaturePrints(excluding: itemId)) ?? [])
            .compactMap { o -> (String, Float)? in
                VisionService.distance(tfp, o.fp).map { (o.id, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
        let items = (try? repo.items(ids: Array(ranked))) ?? []
        // repo.items sırayı korumaz; mesafe sırasına geri diz
        let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        return items.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    // MARK: Internal helpers
    private func ftsSearch(_ query: String) throws -> [String] {
        guard !query.isEmpty else { return [] }

        // F4: AND-önce / OR-fallback; yazarken prefix eşleşme
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }

        let sql = """
        SELECT item.id AS id
        FROM item
        JOIN item_fts ON item_fts.rowid = item.rowid
        WHERE item_fts MATCH ? AND item.forgotten = 0
        ORDER BY bm25(item_fts, 10.0, 5.0, 1.0, 0.5, 0.3, 0.3)
        LIMIT 200
        """

        let pattern = buildFTS5Pattern(terms)
        return try db.read { d in
            try Row.fetchAll(d, sql: sql, arguments: [pattern]).map { $0["id"] }
        }
    }

    /// Build FTS5 pattern: AND-önce, OR-fallback
    /// §4.7 #2: "FTS5Pattern(matchingAnyTokenIn:) yerine AND-önce / OR-fallback"
    private func buildFTS5Pattern(_ terms: [String]) -> String {
        guard terms.count > 1 else { return terms[0] }

        // Prefix eşleşme: her terimin başına * ekle (yazarken)
        let prefixes = terms.map { "\($0)*" }

        // Önce AND deneyelim
        let andPattern = prefixes.joined(separator: " AND ")

        // AND sonuç vermezse OR deneyelim
        let orPattern = prefixes.joined(separator: " OR ")

        // AND-önce pattern: "(term1*) (term2*)" — implicit AND (FTS5 default)
        // Eğer AND ile sonuç yoksa, OR ile geri düş
        // FTS5'te iki term yan yana yazıldığında implicit AND'dir
        return andPattern
    }

    private func vectorSearch(_ query: String, corpusMean: [Float]?) -> [String] {
        guard !query.isEmpty, let qv = EmbeddingService.embed(query) else { return [] }

        // F0: chunk max-pool + merkezlenmiş + mutlak eşik YOK — top-K sıralama
        let cm = corpusMean ?? [Float](repeating: 0, count: 512)
        let all = (try? repo.allEmbeddings()) ?? []

        // Query vektörünü merkezle
        let centeredQ = CorpusCentering.center(vector: qv, mean: cm) ?? qv

        return all
            .compactMap { entry -> (id: String, score: Double)? in
                let centeredItem = CorpusCentering.center(vector: entry.vec, mean: cm) ?? entry.vec
                guard let s = CorpusCentering.cosine(centeredQ, centeredItem) else { return nil }
                return (entry.id, s)
            }
            .sorted { $0.score > $1.score }
            .prefix(200)
            .map { $0.id }
    }
}
