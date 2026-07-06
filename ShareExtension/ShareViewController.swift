import UIKit
import UniformTypeIdentifiers

/// HAFİF extension (spec §3.2): ham veriyi App Group DB'ye `pending` yazar, ÇIKAR.
/// Enrichment ana app'te (bellek limiti ~120MB — Vision/STT burada ÇALIŞTIRILMAZ).
/// Target membership: Models, DatabaseManager, ItemRepository, Stores, IngestionService.
class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleShare()
    }

    private func handleShare() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else { return complete() }

        let group = DispatchGroup()
        var detected: DetectedContent?

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { obj, _ in
                    if let u = obj as? URL, u.scheme?.hasPrefix("http") == true {
                        detected = .url(u)
                    }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    // Geçici URL — closure dönmeden App Group'a kopyalanmalı
                    if let url { detected = .video(url); _ = detected.map(self.captureNow) ; detected = nil }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    if let url { detected = .pdf(url); _ = detected.map(self.captureNow); detected = nil }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { detected = .image(data) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { obj, _ in
                    if let s = obj as? String { detected = .text(s) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if let detected { self.captureNow(detected) }
            self.complete()
        }
    }

    /// Senkron, hafif: asset kopyası + DB insert. loadFileRepresentation'ın geçici
    /// dosyası closure içinde kopyalandığı için burada çağrılır.
    private func captureNow(_ content: DetectedContent) {
        _ = try? IngestionService.capture(content)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
