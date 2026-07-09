import Foundation
import GRDB

struct ItemRepository: Sendable {
    let db = DatabaseManager.shared.dbPool

    // MARK: Yazma
    func save(_ item: inout Item) throws {
        var it = item; it.updatedAt = Date(); it.dirty = true
        try db.write { d in try it.save(d) }
        item = it
    }

    /// F1: içerik güncelleme (başlık + metin) — dirty=true, status=pending
    func updateContent(id: String, title: String?, text: String?) throws {
        try db.write { d in
            var assignments: [ColumnAssignment] = [
                Column("updatedAt").set(to: Date()),
                Column("dirty").set(to: true),
                Column("status").set(to: ItemStatus.pending.rawValue)
            ]
            if let title = title {
                assignments.append(Column("title").set(to: title))
            } else {
                assignments.append(Column("title").set(to: Optional<String>.none))
            }
            if let text = text {
                assignments.append(Column("textContent").set(to: text))
            }
            try Item.filter(key: id).updateAll(d, assignments)
        }
    }

    func attachTags(_ names: [String], to itemId: String, source: String = "auto", kind: TagKind = .keyword) throws {
        try db.write { d in
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard name.count > 1 else { continue }
                var tag = try Tag.filter(Column("name") == name).fetchOne(d)
                    ?? Tag(name: name, source: source, kind: kind)
                try tag.save(d)
                try ItemTag(itemId: itemId, tagId: tag.id).insert(d, onConflict: .ignore)
            }
        }
    }

    func setMeta(_ pairs: [String: String], itemId: String) throws {
        try db.write { d in
            for (k, v) in pairs { try MetaField(itemId: itemId, key: k, value: v).insert(d) }
        }
    }

    func setStatus(_ status: ItemStatus, id: String, bumpAttempts: Bool = false) throws {
        try db.write { d in
            var assignments: [ColumnAssignment] = [
                Column("status").set(to: status.rawValue),
                Column("updatedAt").set(to: Date())]
            if bumpAttempts {
                assignments.append(Column("enrichAttempts").set(to: Column("enrichAttempts") + 1))
            }
            try Item.filter(key: id).updateAll(d, assignments)
        }
    }

    func setPinned(_ pinned: Bool, id: String) throws {
        try db.write { d in
            try Item.filter(key: id).updateAll(d,
                Column("isPinned").set(to: pinned),
                Column("updatedAt").set(to: Date()),
                Column("dirty").set(to: true))
        }
    }

    func setForgotten(_ forgotten: Bool, id: String) throws {
        try db.write { d in
            try Item.filter(key: id).updateAll(d,
                Column("forgotten").set(to: forgotten),
                Column("updatedAt").set(to: Date()),
                Column("dirty").set(to: true))
        }
    }

    // MARK: Okuma
    func timeline(includeForgotten: Bool = false) throws -> [Item] {
        try db.read { d in
            var q = Item.order(Column("isPinned").desc, Column("createdAt").desc)
            if !includeForgotten { q = q.filter(Column("forgotten") == false) }
            return try q.fetchAll(d)
        }
    }

    func item(id: String) throws -> Item? {
        try db.read { try Item.fetchOne($0, key: id) }
    }

    func items(ids: [String]) throws -> [Item] {
        try db.read { d in try Item.filter(ids.contains(Column("id"))).fetchAll(d) }
    }

    /// Enrichment kuyruğu: pending + 3 denemeden az.
    func pendingItems(maxAttempts: Int = 3) throws -> [Item] {
        try db.read { d in
            try Item.filter(Column("status") == ItemStatus.pending.rawValue
                            && Column("enrichAttempts") < maxAttempts)
                .order(Column("createdAt"))
                .fetchAll(d)
        }
    }

    func randomItems(_ n: Int = 10) throws -> [Item] {
        try db.read { d in
            try Item.filter(Column("forgotten") == false)
                .order(sql: "RANDOM()").limit(n).fetchAll(d)
        }
    }

    func allEmbeddings() throws -> [(id: String, vec: [Float])] {
        try db.read { d in
            try Item.filter(Column("embedding") != nil && Column("forgotten") == false)
                .fetchAll(d)
                .compactMap { it in it.embedding.map { (it.id, VectorStore.decode($0)) } }
        }
    }

    func allFeaturePrints(excluding id: String) throws -> [(id: String, fp: Data)] {
        try db.read { d in
            try Item.filter(Column("featurePrint") != nil && Column("id") != id)
                .fetchAll(d)
                .compactMap { it in it.featurePrint.map { (it.id, $0) } }
        }
    }

    /// Detay ekranı etiket çipleri için.
    func tags(for itemId: String) throws -> [String] {
        try db.read { d in
            try String.fetchAll(d, sql: """
                SELECT tag.name FROM tag
                JOIN item_tag ON item_tag.tagId = tag.id
                WHERE item_tag.itemId = ?
                ORDER BY tag.name
                """, arguments: [itemId])
        }
    }

    /// F2: topic bazlı etiketler
    func topicTags(for itemId: String) throws -> [(topicId: String, name: String, score: Double)] {
        try db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT it.topicId, t.name, it.score
                FROM item_topic it
                JOIN topic t ON t.id = it.topicId
                WHERE it.itemId = ?
                ORDER BY it.score DESC
                """, arguments: [itemId]).map { ($0["topicId"] as! String, $0["name"] as! String, $0["score"] as! Double) }
        }
    }

    /// Knowledge graph (E2): >= minShared ortak etikete sahip item çiftleri.
    func sharedTagPairs(minShared: Int = 2) throws -> [(a: String, b: String, shared: Int)] {
        try db.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT t1.itemId AS a, t2.itemId AS b, COUNT(*) AS c
                FROM item_tag t1
                JOIN item_tag t2 ON t1.tagId = t2.tagId AND t1.itemId < t2.itemId
                GROUP BY t1.itemId, t2.itemId
                HAVING c >= ?
                LIMIT 2000
                """, arguments: [minShared])
            return rows.map { ($0["a"], $0["b"], $0["c"]) }
        }
    }

    // MARK: Spaces
    func spaces() throws -> [Space] {
        try db.read { try Space.order(Column("createdAt").desc).fetchAll($0) }
    }
    func saveSpace(_ space: Space) throws {
        var s = space
        try db.write { try s.save($0) }
    }
    func deleteSpace(id: String) throws {
        _ = try db.write { try Space.deleteOne($0, key: id) }
    }

    // MARK: Topic Taksonomisi (F2)
    func topics() throws -> [Topic] {
        try db.read { try Topic.order(Column("createdAt")).fetchAll($0) }
    }
    func saveTopic(_ topic: Topic) throws {
        var t = topic
        try db.write { try t.save($0) }
    }
    func deleteTopic(id: String) throws {
        _ = try db.write { try Topic.deleteOne($0, key: id) }
    }
    func saveTopicPhrases(topicId: String, phrases: [String]) throws {
        try db.write { d in
            _ = try TopicPhrase.filter(Column("topicId") == topicId).fetchAll(d)
                .forEach { try $0.destroy(d) }
            for p in phrases {
                try TopicPhrase(topicId: topicId, phrase: p).insert(d)
            }
        }
    }
    func saveItemTopics(itemId: String, topics: [(topicId: String, score: Double, source: String)]) throws {
        try db.write { d in
            _ = try ItemTopic.filter(Column("itemId") == itemId).fetchAll(d)
                .forEach { try $0.destroy(d) }
            for (tid, score, source) in topics {
                try ItemTopic(itemId: itemId, topicId: tid, score: score, source: source).insert(d, onConflict: .ignore)
            }
        }
    }
    func topicsForItem(itemId: String) throws -> [(topicId: String, name: String, score: Double, source: String)] {
        try db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT it.itemId, it.topicId, t.name, it.score, it.source
                FROM item_topic it
                JOIN topic t ON t.id = it.topicId
                WHERE it.itemId = ?
                """, arguments: [itemId]).map {
                    ($0["itemId"] as! String, $0["name"] as! String, $0["score"] as! Double, $0["source"] as! String)
                }
        }
    }

    // MARK: Item Chunking (F0)
    func saveChunks(itemId: String, chunks: [(idx: Int, vector: Data)]) throws {
        try db.write { d in
            _ = try ItemChunk.filter(Column("itemId") == itemId).fetchAll(d)
                .forEach { try $0.destroy(d) }
            for (idx, vec) in chunks {
                try ItemChunk(itemId: itemId, idx: idx, vector: vec).insert(d, onConflict: .replace)
            }
        }
    }
    func deleteChunks(itemId: String) throws {
        try db.write { d in
            try ItemChunk.filter(Column("itemId") == itemId).fetchAll(d)
                .forEach { try $0.destroy(d) }
        }
    }
    func chunkVectors(itemId: String) throws -> [(idx: Int, vec: [Float])] {
        try db.read { d in
            try ItemChunk.filter(Column("itemId") == itemId)
                .order(Column("idx"))
                .fetchAll(d)
                .compactMap { c in c.vector.map { (c.idx, VectorStore.decode($0)) } }
        }
    }

    // MARK: Graph (F3)
    func saveManualEdge(_ edge: ManualEdge) throws {
        var e = edge
        try db.write { try e.save($0) }
    }
    func deleteManualEdges(batchId: String?) throws {
        try db.write { d in
            if let batchId = batchId {
                try ManualEdge.filter(Column("batchId") == batchId).fetchAll(d)
                    .forEach { try $0.destroy(d) }
            } else {
                try ManualEdge.all().fetchAll(d).forEach { try $0.destroy(d) }
            }
        }
    }
    func manualEdges() throws -> [ManualEdge] {
        try db.read { try ManualEdge.order(Column("createdAt").desc).fetchAll($0) }
    }
    func saveGraphPositions(positions: [(nodeKey: String, x: Double, y: Double, pinned: Bool)]) throws {
        try db.write { d in
            for pos in positions {
                var gp = try GraphPosition.filter(Column("nodeKey") == pos.nodeKey).fetchOne(d)
                    ?? GraphPosition(nodeKey: pos.nodeKey)
                gp.x = pos.x
                gp.y = pos.y
                gp.pinned = pos.pinned
                try gp.save(d)
            }
        }
    }
    func graphPositions() throws -> [(nodeKey: String, x: Double, y: Double, pinned: Bool)] {
        try db.read { d in
            try GraphPosition.fetchAll(d)
                .map { ($0.nodeKey, $0.x, $0.y, $0.pinned) }
        }
    }

    // MARK: Profile Nodes (F3)
    func saveProfileNode(_ node: ProfileNode) throws {
        var n = node
        try db.write { try n.save($0) }
    }
    func profileNodes() throws -> [ProfileNode] {
        try db.read { try ProfileNode.fetchAll($0) }
    }
    func saveProfileTopics(profileId: String, topicIds: [String]) throws {
        try db.write { d in
            _ = try ProfileTopic.filter(Column("profileId") == profileId).fetchAll(d)
                .forEach { try $0.destroy(d) }
            for tid in topicIds {
                try ProfileTopic(profileId: profileId, topicId: tid).insert(d, onConflict: .ignore)
            }
        }
    }

    // MARK: Embedding Meta (F0: corpus mean μ)
    func saveEmbeddingMeta(model: String, revision: Int, totalVector: [Float], count: Int, frozenMu: [Float]) throws {
        let blob = VectorStore.encode(frozenMu)
        try db.write { d in
            try embedding_meta_table().upsert(d, key: "global", values: [
                Column("vector"): blob,
                Column("count"): count,
                Column("model"): model,
                Column("revision"): revision
            ])
        }
    }
    func loadEmbeddingMeta() throws -> (model: String, revision: Int, totalVector: [Float], count: Int, mu: [Float])? {
        try db.read { d in
            try embedding_meta_table().filter(key: "global").fetchOne(d).map { row in
                let model = row["model"] as! String
                let rev = row["revision"] as! Int
                let count = row["count"] as! Int
                let mu = VectorStore.decode(row["vector"] as! Data)
                // totalVector approximate: μ * count (exact total is harder to reconstruct)
                let total = mu.map { $0 * Float(count) }
                return (model, rev, total, count, mu)
            }
        }
    }

    // MARK: Reindex (F0: tüm embedding'leri sıfırla)
    func resetEmbeddingMetadata() throws {
        try db.write { d in
            try Item.filter(Column("status") != ItemStatus.failed)
                .updateAll(d,
                    Column("status").set(to: ItemStatus.pending.rawValue),
                    Column("embedding").set(to: Optional<Data>.none),
                    Column("embeddingModel").set(to: Optional<String>.none),
                    Column("embeddingRevision").set(to: Optional<Int>.none))
            // item_chunk tablosunu temizle
            try ItemChunk.all().fetchAll(d).forEach { try $0.destroy(d) }
        }
    }

    // Helper: embedding_meta tablosu için raw SQL
    private func embedding_meta_table() -> Table {
        Table("embedding_meta")
    }
}
