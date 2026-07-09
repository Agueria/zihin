import Foundation

/// HAFİF capture (spec §3.2): ham veriyi `pending` Item olarak yazar, ağır iş yapmaz.
/// Hem Share Extension hem ana app kullanır. Enrichment: EnrichmentQueue (yalnız ana app).
enum IngestionService {
    @discardableResult
    static func capture(_ content: DetectedContent) throws -> Item {
        let repo = ItemRepository()
        var item: Item
        switch content {
        case .text(let s):
            item = Item(type: .note, textContent: s)
            // F1: başlık prefix(80) halesi KALDIRILDI — title boş, görünümde türetilir
        case .url(let u):
            item = Item(type: .link, url: u.absoluteString)
            item.title = u.host
        case .image(let data):
            item = Item(type: .image)
            item.assetPath = AssetStore.save(data, ext: "jpg")
        case .video(let u):
            item = Item(type: .video)
            item.assetPath = AssetStore.copy(fileURL: u,
                ext: u.pathExtension.isEmpty ? "mp4" : u.pathExtension)
        case .pdf(let u):
            item = Item(type: .pdf)
            item.assetPath = AssetStore.copy(fileURL: u, ext: "pdf")
            item.title = u.deletingPathExtension().lastPathComponent
        }
        try repo.save(&item)
        return item
    }

    /// F1: içerik güncelleme
    static func updateContent(itemId: String, title: String?, text: String?) throws {
        let repo = ItemRepository()
        try repo.updateContent(id: itemId, title: title, text: text)
    }
}
