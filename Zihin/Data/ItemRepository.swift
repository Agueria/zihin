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
