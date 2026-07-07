import Foundation

/// E1 (spec §10): her item -> Markdown + YAML frontmatter. "Own your data."
/// Kullanıcının seçtiği klasöre (security-scoped) yazar; Obsidian vault'u olabilir.
enum ObsidianExporter {
    enum ExportError: Error { case folderAccessDenied }

    @discardableResult
    static func export(to folder: URL) throws -> Int {
        let repo = ItemRepository()
        let items = try repo.timeline(includeForgotten: true)
        guard folder.startAccessingSecurityScopedResource() else {
            throw ExportError.folderAccessDenied
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        let df = ISO8601DateFormatter()
        for item in items {
            let tags = (try? repo.tags(for: item.id)) ?? []
            let md = markdown(item, tags: tags, dateFormatter: df)
            let url = folder.appendingPathComponent(fileName(item))
            try md.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        return items.count
    }

    static func fileName(_ item: Item) -> String {
        var slug = ""
        for ch in (item.title ?? item.type.rawValue).lowercased() {
            if ch.isLetter || ch.isNumber { slug.append(ch) }
            else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(item.id.prefix(8))-\(slug.prefix(40)).md"
    }

    static func markdown(_ item: Item, tags: [String],
                         dateFormatter df: ISO8601DateFormatter) -> String {
        var fm = ["---",
                  "id: \(item.id)",
                  "type: \(item.type.rawValue)",
                  "created: \(df.string(from: item.createdAt))"]
        if let u = item.url { fm.append("source: \(u)") }
        if !item.colors.isEmpty { fm.append("colors: [\(item.colors.joined(separator: ", "))]") }
        if !tags.isEmpty { fm.append("tags: [\(tags.joined(separator: ", "))]") }
        fm.append("---")

        var parts = [fm.joined(separator: "\n")]
        if let t = item.title, !t.isEmpty { parts.append("# \(t)") }
        if let s = item.summary, !s.isEmpty { parts.append("> \(s)") }
        if let c = item.textContent, !c.isEmpty { parts.append(c) }
        if let o = item.ocrText, !o.isEmpty { parts.append("## Görseldeki metin\n\n\(o)") }
        if let tr = item.transcript, !tr.isEmpty { parts.append("## Konuşma\n\n\(tr)") }
        if let f = item.frameText, !f.isEmpty { parts.append("## Karelerdeki yazı\n\n\(f)") }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
