import Foundation
import SwiftSoup
import UIKit

struct LinkMetadata: Sendable {
    var title: String?
    var description: String?
    var imageURL: URL?
    var siteName: String?
    var rawHTML: String?
}

enum LinkMetadataService {
    /// OG/meta fetch. og:video BİLEREK parse edilmez (spec §7: uzak video asla çekilmez).
    static func fetch(_ url: URL) async throws -> LinkMetadata {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (compatible; ZihinBot/1.0)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return LinkMetadata() }
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        var og: [String: String] = [:]
        for m in try doc.select("meta") {
            let key = (try? m.attr("property")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? m.attr("name")) ?? ""
            let content = (try? m.attr("content")) ?? ""
            if !key.isEmpty, !content.isEmpty, og[key] == nil { og[key] = content }
        }
        var meta = LinkMetadata()
        meta.title = og["og:title"] ?? (try? doc.title())
        meta.description = og["og:description"] ?? og["description"]
        meta.siteName = og["og:site_name"] ?? url.host
        if let s = og["og:image"], let u = URL(string: s, relativeTo: url) { meta.imageURL = u.absoluteURL }
        meta.rawHTML = html
        return meta
    }
}

/// Reader mode — SwiftSoup heuristiği (bağımlılık yok). Yetersiz kalırsa v1.x'te Readability.js.
enum ReadabilityService {
    static func extract(html: String, baseURL: URL) -> (contentHTML: String, text: String) {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return ("", "") }
        for tag in ["script","style","nav","aside","footer","header","form","noscript","iframe","svg"] {
            try? doc.select(tag).remove()
        }
        let candidates = try? doc.select("article, main, [role=main], .post, .article, #content")
        guard let container = candidates?.first() ?? doc.body() else { return ("", "") }
        let inner = (try? container.outerHtml()) ?? ""
        let text = (try? container.text()) ?? ""
        let wrapped = """
        <html><head><meta name='viewport' content='width=device-width, initial-scale=1'>
        <style>body{font:17px/1.6 -apple-system;margin:0;padding:20px;color:#111;background:#fff;}
        @media (prefers-color-scheme: dark){body{background:#111;color:#eee;}}
        img{max-width:100%;height:auto;border-radius:10px;}h1,h2,h3{line-height:1.25;}p{margin:0 0 1em;}
        </style></head><body>\(inner)</body></html>
        """
        return (wrapped, text)
    }
}

/// Link enrichment (normal + social tek akış, spec §7).
/// Social linkte sinyal = poster karesi + caption; uzak video HİÇBİR koşulda indirilmez.
enum LinkEnricher {
    private static let socialHosts = [
        "instagram.com", "tiktok.com", "youtube.com", "youtu.be",
        "twitter.com", "x.com", "vimeo.com", "reddit.com"]

    static func isSocial(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return socialHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func enrich(_ item: inout Item) async throws -> [String] {
        guard let s = item.url, let url = URL(string: s) else {
            throw EnrichmentQueue.EnrichError.badURL
        }
        let meta = try await LinkMetadataService.fetch(url)
        item.title = meta.title ?? url.host
        item.siteName = meta.siteName
        let caption = [meta.title, meta.description].compactMap { $0 }.joined(separator: " ")

        // Makale gövdesi (social'da caption yeterli, reader denenmez)
        if !isSocial(url), let html = meta.rawHTML {
            let reader = ReadabilityService.extract(html: html, baseURL: url)
            if reader.text.count > 200 {
                item.readerHTML = reader.contentHTML
                item.textContent = reader.text
                item.summary = SummaryService.summarize(reader.text, n: 3)
            }
        }
        if item.textContent == nil, !caption.isEmpty {
            item.textContent = caption
            item.summary = SummaryService.summarize(caption, n: 2)
        }

        // Poster GÖRSELİ indirilebilir (video değil) -> image pipeline
        var posterTags: [String] = []
        if let iu = meta.imageURL,
           let (d, _) = try? await URLSession.shared.data(from: iu),
           let cg = UIImage(data: d)?.cgImage {
            item.posterPath = AssetStore.save(d, ext: "jpg")
            let v = VisionService.analyze(cgImage: cg)
            item.ocrText = v.ocrText
            item.featurePrint = v.featurePrint
            item.colors = ColorService.dominantColorNames(cgImage: cg)
            posterTags = v.classifications + item.colors
                + LanguageService.namedEntities(v.ocrText)
        }

        let base = [caption, item.textContent ?? "", item.ocrText ?? ""]
            .joined(separator: " ")
        item.lang = LanguageService.dominantLanguage(base)
        // v2 (§4.1): embedding + chunk + μ artık EnrichmentQueue'da merkezî üretiliyor.
        return posterTags + LanguageService.namedEntities(caption) + KeywordService.keywords(base)
    }
}
