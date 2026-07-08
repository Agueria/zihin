import Foundation
import GRDB

// MARK: - Sorgu ayrıştırma (renk + tarih sinyalleri)

struct ParsedQuery: Sendable {
    var cleaned: String
    var colors: [String]
    var dateRange: (start: Date, end: Date)?
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

        return ParsedQuery(cleaned: tokens.joined(separator: " "), colors: colors, dateRange: range)
    }
}

// MARK: - Hybrid arama (FTS5 + cosine + RRF, spec §6)

struct SearchService: Sendable {
    let db = DatabaseManager.shared.dbPool
    private let repo = ItemRepository()

    func search(_ rawQuery: String, limit: Int = 50) async -> [Item] {
        let q = SearchQueryParser.parse(rawQuery)

        let ftsRanked = (try? ftsSearch(q.cleaned)) ?? []
        let vecRanked = vectorSearch(q.cleaned)

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
        return items
            .filter { !$0.forgotten }
            .sorted { (score[$0.id] ?? 0) > (score[$1.id] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    private func ftsSearch(_ query: String) throws -> [String] {
        guard !query.isEmpty, let pattern = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        return try db.read { d in
            let sql = """
            SELECT item.id AS id
            FROM item
            JOIN item_fts ON item_fts.rowid = item.rowid
            WHERE item_fts MATCH ? AND item.forgotten = 0
            ORDER BY bm25(item_fts)
            LIMIT 200
            """
            return try Row.fetchAll(d, sql: sql, arguments: [pattern]).map { $0["id"] }
        }
    }

    private func vectorSearch(_ query: String) -> [String] {
        guard !query.isEmpty, let qv = EmbeddingService.embed(query) else { return [] }
        // v2 (§4.7): merkezlenmiş cosine + chunk max-pool. MUTLAK EŞİK YOK — top-K sıralama.
        // Ham cosine `> 0.15` (kök neden A'nın semptomu) kaldırıldı; her şey geçmiyor.
        let mu = (try? db.read { try CenteringStore.frozenMu($0).mu }) ?? []
        let pools = (try? repo.allChunkPools()) ?? []
        let source: [(id: String, vec: [Float])] = pools.isEmpty
            ? ((try? repo.allEmbeddings()) ?? [])                 // chunk yoksa doküman vektörü
            : pools.map { (id: $0.id, vec: $0.pool) }
        return source
            .map { (id: $0.id, s: Centered.cosine(qv, $0.vec, mu: mu)) }
            .sorted { $0.s > $1.s }
            .prefix(200)
            .map { $0.id }
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
}
