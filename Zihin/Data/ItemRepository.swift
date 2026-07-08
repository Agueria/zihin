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

    func attachTags(_ names: [String], to itemId: String, source: String = "auto") throws {
        try db.write { d in
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard name.count > 1 else { continue }
                var tag = try Tag.filter(Column("name") == name).fetchOne(d)
                    ?? Tag(name: name, source: source)
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

    // MARK: v2 — chunk vektörleri, reindex, düzenleme (§4.1c/§4.5/§4.8)

    /// Item'ın chunk vektörlerini değiştir (reindex'te eskiler silinir).
    func saveChunks(_ vectors: [[Float]], itemId: String) throws {
        try db.write { d in
            try ItemChunk.filter(Column("itemId") == itemId).deleteAll(d)
            for (i, v) in vectors.enumerated() {
                try ItemChunk(itemId: itemId, idx: i, vector: VectorStore.encode(v)).insert(d)
            }
        }
    }

    /// Arama max-pool için tek item'ın chunk vektörleri.
    func chunks(itemId: String) throws -> [[Float]] {
        try db.read { d in
            try ItemChunk.filter(Column("itemId") == itemId)
                .order(Column("idx"))
                .fetchAll(d)
                .map { VectorStore.decode($0.vector) }
        }
    }

    /// Tüm item'lar için (id, chunk max-pool) — merkezlenmiş vektör aramasının girdisi (§4.7).
    func allChunkPools() throws -> [(id: String, pool: [Float])] {
        try db.read { d in
            let rows = try ItemChunk.order(Column("itemId"), Column("idx")).fetchAll(d)
            var byItem: [String: [[Float]]] = [:]
            for r in rows { byItem[r.itemId, default: []].append(VectorStore.decode(r.vector)) }
            return byItem.map { (id: $0.key, pool: Pooling.maxPool($0.value)) }
        }
    }

    /// Aktif modelle uyuşmayan veya embedding'i olmayan item'lar → reindex (§4.1a/§4.8).
    func itemsNeedingReindex(model: String, revision: Int) throws -> [Item] {
        try db.read { d in
            try Item.filter(Column("forgotten") == false)
                .filter(Column("embedding") == nil
                        || Column("embeddingModel") != model
                        || Column("embeddingRevision") != revision)
                .fetchAll(d)
        }
    }

    /// Not düzenleme (§4.5): içerik/başlık değişince yeniden indeksle.
    func updateContent(id: String, title: String?, text: String) throws {
        try db.write { d in
            try Item.filter(key: id).updateAll(d,
                Column("title").set(to: title),
                Column("textContent").set(to: text),
                Column("status").set(to: ItemStatus.pending.rawValue),
                Column("embedding").set(to: nil),
                Column("dirty").set(to: true),
                Column("updatedAt").set(to: Date()))
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
}
