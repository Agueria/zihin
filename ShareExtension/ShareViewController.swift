import UIKit
import UniformTypeIdentifiers

/// HAFİF extension (spec §3.2): ham veriyi App Group DB'ye `pending` yazar, ÇIKAR.
/// Enrichment ana app'te (extension bellek limiti ~120MB — Vision/STT burada YOK).
/// Target membership: Models, DatabaseManager, ItemRepository, Stores, IngestionService.
class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        handleShare()
    }

    private func handleShare() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else { return complete() }

        let collector = ShareCollector()
        let group = DispatchGroup()

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    // Geçici dosya closure dönmeden App Group'a kopyalanmalı -> hemen capture
                    if let url { _ = try? IngestionService.capture(.video(url)); collector.markFileCaptured() }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    if let url { _ = try? IngestionService.capture(.pdf(url)); collector.markFileCaptured() }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { obj, _ in
                    if let u = obj as? URL, u.scheme?.hasPrefix("http") == true { collector.set(url: u) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { collector.set(image: data) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { obj, _ in
                    if let s = obj as? String { collector.set(text: s) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            // Öncelik: dosya (zaten yakalandı) > URL > görsel > metin.
            // Safari URL + metin birlikte paylaşır; URL kartı esas alınır.
            if let content = collector.best() {
                _ = try? IngestionService.capture(content)
            }
            self.complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

/// Provider callback'leri farklı thread'lerden gelir; toplama kilitli yapılır.
final class ShareCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var image: Data?
    private var text: String?
    private var fileCaptured = false

    func set(url u: URL) { lock.lock(); url = u; lock.unlock() }
    func set(image d: Data) { lock.lock(); image = d; lock.unlock() }
    func set(text s: String) { lock.lock(); text = s; lock.unlock() }
    func markFileCaptured() { lock.lock(); fileCaptured = true; lock.unlock() }

    func best() -> DetectedContent? {
        lock.lock(); defer { lock.unlock() }
        if fileCaptured { return nil }          // video/pdf zaten kaydedildi
        if let url { return .url(url) }
        if let image { return .image(image) }
        if let text { return .text(text) }
        return nil
    }
}
