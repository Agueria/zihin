import Foundation

// E2 (spec §10): Obsidian-vari bilgi grafiği. Kenarlar OTOMATİK türetilir:
// (1) embedding benzerliği (anlam bağı), (2) ortak etiketler (etiket bağı).
// Hepsi cihazda, $0.

struct GraphNode: Identifiable, Sendable {
    let id: String                 // item id
    let title: String
    let type: ItemType
    var degree: Int = 0
    var x: Double = 0.5            // layout sonucu, 0-1 normalize
    var y: Double = 0.5
}

struct GraphEdge: Identifiable, Sendable {
    enum Kind: Sendable { case semantic, tag }
    let a: String
    let b: String
    let weight: Double             // 0-1
    let kind: Kind
    var id: String { "\(a)|\(b)" }
}

struct KnowledgeGraphData: Sendable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var isolatedCount: Int         // bağlantısız (gizlenen) kayıt sayısı
}

enum KnowledgeGraph {
    /// Son `maxItems` kayıttan grafiği kurar. 250 × 250 benzerlik + 150 iterasyon
    /// force layout cihazda ~1 sn; daha fazlası zaten okunmaz.
    static func build(maxItems: Int = 250,
                      minSimilarity: Float = 0.5,
                      maxSemanticEdgesPerNode: Int = 3) throws -> KnowledgeGraphData {
        let repo = ItemRepository()
        let items = Array(try repo.timeline().prefix(maxItems))

        var vecs: [String: [Float]] = [:]
        for it in items {
            if let e = it.embedding { vecs[it.id] = VectorStore.decode(e) }
        }
        var nodes = items.map { it in
            GraphNode(id: it.id,
                      title: it.title ?? it.textContent.map { String($0.prefix(40)) }
                             ?? it.type.rawValue,
                      type: it.type)
        }
        let ids = nodes.map(\.id)
        let idSet = Set(ids)

        // 1) Anlam bağları: düğüm başına en güçlü N (eşik üstü)
        var edges: [GraphEdge] = []
        var seen = Set<String>()
        for i in 0..<ids.count {
            guard let vi = vecs[ids[i]] else { continue }
            var best: [(j: Int, s: Float)] = []
            for j in 0..<ids.count where j != i {
                guard let vj = vecs[ids[j]] else { continue }
                let s = VectorStore.cosine(vi, vj)
                if s >= minSimilarity { best.append((j, s)) }
            }
            for (j, s) in best.sorted(by: { $0.s > $1.s }).prefix(maxSemanticEdgesPerNode) {
                let key = ids[i] < ids[j] ? "\(ids[i])|\(ids[j])" : "\(ids[j])|\(ids[i])"
                guard seen.insert(key).inserted else { continue }
                edges.append(GraphEdge(a: ids[i], b: ids[j],
                                       weight: Double(s), kind: .semantic))
            }
        }

        // 2) Etiket bağları: >=2 ortak etiket (anlam bağı yoksa)
        for pair in try repo.sharedTagPairs(minShared: 2) {
            guard idSet.contains(pair.a), idSet.contains(pair.b) else { continue }
            let key = pair.a < pair.b ? "\(pair.a)|\(pair.b)" : "\(pair.b)|\(pair.a)"
            guard seen.insert(key).inserted else { continue }
            edges.append(GraphEdge(a: pair.a, b: pair.b,
                                   weight: min(1.0, Double(pair.shared) / 4.0), kind: .tag))
        }

        // 3) Derece + izole düğümleri gizle (grafiği okunur tut)
        var degree: [String: Int] = [:]
        for e in edges {
            degree[e.a, default: 0] += 1
            degree[e.b, default: 0] += 1
        }
        for i in nodes.indices { nodes[i].degree = degree[nodes[i].id] ?? 0 }
        let isolated = nodes.filter { $0.degree == 0 }.count
        nodes.removeAll { $0.degree == 0 }

        // 4) Force-directed yerleşim (Fruchterman-Reingold)
        layout(&nodes, edges: edges)
        return KnowledgeGraphData(nodes: nodes, edges: edges, isolatedCount: isolated)
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

        let k = 1.0 / (Double(n).squareRoot() * 1.2)   // ideal mesafe
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
