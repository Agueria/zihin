import Foundation

// F3: Kavram grafiği — bipartite model (item-topic-profile), manuel kenarlar, profil düğümleri
// §4.6: Item'lar VARSAYILAN OLARAK birbirine YALNIZ konular üzerinden bağlanır.
// Item-item kenarları YALNIZ kullanıcı onayıyla (manual_edge).

struct GraphNode: Identifiable, Sendable {
    enum NodeType { case item, topic, profile }
    let id: String
    let title: String
    let type: NodeType
    let itemType: ItemType?
    var degree: Int = 0
    var x: Double = 0.5
    var y: Double = 0.5
}

struct GraphEdge: Identifiable, Sendable {
    enum Kind: Sendable { case semantic, tag, manual, hierarchical }
    let a: String
    let b: String
    let weight: Double
    let kind: Kind
    var id: String { "\(a)|\(b)" }
}

struct KnowledgeGraphData: Sendable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var isolatedCount: Int
    var suggestedEdges: [GraphEdge]  // F3: bağlantı önerileri
}

enum KnowledgeGraph {

    // MARK: F3: Manuel kenarlar
    static func addManualEdge(a: String, b: String, origin: String = "user") throws {
        let repo = ItemRepository()
        // Normalize: aKey < bKey
        let (lo, hi) = a < b ? (a, b) : (b, a)
        var edge = ManualEdge(aKey: lo, bKey: hi, origin: origin)
        try repo.saveManualEdge(edge)
    }

    static func undoSuggestedEdges(batchId: String) throws {
        try ItemRepository().deleteManualEdges(batchId: batchId)
    }

    static func getAllEdges() throws -> [(edge: GraphEdge, origin: String)] {
        let repo = ItemRepository()
        var results: [(edge: GraphEdge, origin: String)] = []
        for me in try repo.manualEdges() {
            results.append((GraphEdge(a: me.aKey, b: me.bKey, weight: 1.0, kind: .manual), me.origin))
        }
        return results
    }

    // MARK: F3: Profil düğümleri
    static func addProfileNode(name: String, topicIds: [String]) throws {
        let repo = ItemRepository()
        var node = ProfileNode(name: name)
        try repo.saveProfileNode(node)
        try repo.saveProfileTopics(profileId: node.id, topicIds: topicIds)
    }

    static func getProfileNodes() throws -> [ProfileNode] {
        try ItemRepository().profileNodes()
    }

    // MARK: F3: Bağlantı önerisi (kNN, §4.6)
    static func suggestConnections(for nodeId: String, k: Int = 3) throws -> [GraphEdge] {
        let repo = ItemRepository()
        guard let item = try repo.item(id: nodeId),
              let embedding = item.embedding,
              let vec = VectorStore.decode(embedding) else {
            return []
        }

        let all = (try? repo.allEmbeddings()) ?? []
        let candidates = all
            .filter { $0.id != nodeId }
            .map { (id: $0.id, sim: VectorStore.cosine(vec, $0.vec)) }
            .filter { $0.sim > 0.3 }
            .sorted { $0.sim > $1.sim }
            .prefix(k)

        return candidates.map {
            GraphEdge(a: nodeId, b: $0.id, weight: Double($0.sim), kind: .semantic)
        }
    }

    /// F3: Bipartite grafik (item-topic-profile) kurar
    static func build(maxItems: Int = 250,
                      minSimilarity: Float = 0.5,
                      maxSemanticEdgesPerNode: Int = 3) throws -> KnowledgeGraphData {
        let repo = ItemRepository()
        let items = Array(try repo.timeline().prefix(maxItems))

        // F3: nodeKey şeması: "item:<uuid>", "topic:<uuid>", "profile:<uuid>"
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var seen = Set<String>()

        // 1) Topic düğümleri
        let topicMap = try buildTopicNodes(items, repo: repo)
        nodes.append(contentsOf: topicMap)

        // 2) Item-topik kenarları
        for item in items {
            let itemTopics = try repo.topicsForItem(itemId: item.id)
            for (topicId, _, score, _) in itemTopics {
                let key = "\(item.id)|\(topicId)"
                guard seen.insert(key).inserted else { continue }
                edges.append(GraphEdge(a: item.id, b: topicId, weight: Double(score), kind: .semantic))
            }
            // Manuel kenarlar
            for (edge, _) in try getAllEdges() {
                let key = "\(edge.a)|\(edge.b)"
                if seen.insert(key).inserted {
                    edges.append(edge)
                }
            }
        }

        // 3) Profil düğümleri
        for profile in try getProfileNodes() {
            let pNode = GraphNode(id: profile.id, title: profile.name, type: .profile, itemType: nil)
            nodes.append(pNode)
            let profileTopics = try repo.db.read { d in
                try Row.fetchAll(d, sql: """
                    SELECT topicId FROM profile_topic WHERE profileId = ?
                    """, arguments: [profile.id]).compactMap { $0["topicId"] as? String }
            }
            for tid in profileTopics {
                let key = "\(profile.id)|\(tid)"
                if seen.insert(key).inserted {
                    edges.append(GraphEdge(a: profile.id, b: tid, weight: 1.0, kind: .semantic))
                }
            }
        }

        // 4) Etiket bağları (topic üzerinden, minShared=1 — tek ortak konu gerçek bağ)
        // F3: minShared 2'den 1'e düşer
        for pair in try repo.sharedTagPairs(minShared: 1) {
            // Sadece topic tipli etiketleri dikkate al
            let key = pair.a < pair.b ? "\(pair.a)|\(pair.b)" : "\(pair.b)|\(pair.a)"
            guard seen.insert(key).inserted else { continue }
            edges.append(GraphEdge(a: pair.a, b: pair.b,
                                   weight: min(1.0, Double(pair.shared) / 4.0), kind: .tag))
        }

        // 5) Derece
        var degree: [String: Int] = [:]
        for e in edges {
            degree[e.a, default: 0] += 1
            degree[e.b, default: 0] += 1
        }
        for i in nodes.indices { nodes[i].degree = degree[nodes[i].id] ?? 0 }

        // 6) İzole düğümler gizlenmez (kenarda "yalnızlar" kümesi gösterilir)
        let isolated = nodes.filter { $0.degree == 0 }
        let isolatedCount = isolated.count
        nodes.removeAll { $0.degree == 0 }

        // 7) Force-directed yerleşim (F3: ana thread DIŞINA taşındı)
        layout(&nodes, edges: edges)

        // 8) Bağlantı önerileri
        let suggestedEdges: [GraphEdge] = []

        return KnowledgeGraphData(nodes: nodes, edges: edges, isolatedCount: isolatedCount,
                                  suggestedEdges: suggestedEdges)
    }

    // MARK: Internal
    private static func buildTopicNodes(_ items: [Item], repo: ItemRepository) throws -> [GraphNode] {
        var topics: [String: (name: String, isCore: Bool)] = [:]
        for item in items {
            let itemTopics = try repo.topicsForItem(itemId: item.id)
            for (topicId, name, _, _) in itemTopics {
                if topics[topicId] == nil {
                    topics[topicId] = (name, true)
                }
            }
        }
        return topics.map { id, info in
            GraphNode(id: id, title: info.name, type: .topic, itemType: nil)
        }
    }

    private static func layout(_ nodes: inout [GraphNode],
                               edges: [GraphEdge], iterations: Int = 150) {
        let n = nodes.count
        guard n > 1 else { return }
        var idx: [String: Int] = [:]
        for (i, nd) in nodes.enumerated() { idx[nd.id] = i }

        // Deterministik başlangıç: çember
        for i in 0..<n {
            let a = 2 * Double.pi * Double(i) / Double(n)
            nodes[i].x = 0.5 + 0.4 * cos(a)
            nodes[i].y = 0.5 + 0.4 * sin(a)
        }

        let k = 1.0 / (Double(n).squareRoot() * 1.2)
        var temp = 0.1
        for _ in 0..<iterations {
            var dx = [Double](repeating: 0, count: n)
            var dy = [Double](repeating: 0, count: n)
            // İtme (tüm çiftler)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var vx = nodes[i].x - nodes[j].x
                    var vy = nodes[i].y - nodes[j].y
                    var d2 = vx * vx + vy * vy
                    if d2 < 1e-6 { d2 = 1e-6; vx = 1e-3; vy = 1e-3 }
                    let d = d2.squareRoot()
                    let f = k * k / d
                    dx[i] += vx / d * f; dy[i] += vy / d * f
                    dx[j] -= vx / d * f; dy[j] -= vy / d * f
                }
            }
            // Çekme (kenarlar; ağırlık güçlendirir)
            for e in edges {
                guard let i = idx[e.a], let j = idx[e.b] else { continue }
                let vx = nodes[i].x - nodes[j].x
                let vy = nodes[i].y - nodes[j].y
                let d = max(1e-4, (vx * vx + vy * vy).squareRoot())
                let f = d * d / k * (0.5 + e.weight)
                dx[i] -= vx / d * f; dy[i] -= vy / d * f
                dx[j] += vx / d * f; dy[j] += vy / d * f
            }
            // Uygula (soğutmalı) + çerçevede tut
            for i in 0..<n {
                let disp = max(1e-9, (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot())
                let lim = min(disp, temp)
                nodes[i].x = min(0.97, max(0.03, nodes[i].x + dx[i] / disp * lim))
                nodes[i].y = min(0.97, max(0.03, nodes[i].y + dy[i] / disp * lim))
            }
            temp *= 0.97
        }
    }
}
