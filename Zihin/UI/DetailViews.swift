import SwiftUI
import WebKit
import AVKit

struct DetailRouter: View {
    let itemId: String
    @State private var item: Item?
    @State private var tags: [String] = []
    private let repo = ItemRepository()

    var body: some View {
        Group {
            if let item {
                switch item.type {
                case .link where item.readerHTML != nil:
                    ArticleDetailView(item: item, tags: tags)
                case .video:
                    VideoDetailView(item: item, tags: tags)
                case .image:
                    ImageDetailView(item: item, tags: tags)
                default:
                    NoteDetailView(item: item, tags: tags)
                }
            } else {
                ContentUnavailableView("Bulunamadı", systemImage: "questionmark.circle")
            }
        }
        .task {
            item = try? repo.item(id: itemId)
            tags = (try? repo.tags(for: itemId)) ?? []
        }
    }
}

/// Ortak üst blok: tarih · kaynak eyebrow + etiket çipleri.
struct DetailMeta: View {
    let item: Item
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: [item.createdAt.formatted(date: .abbreviated, time: .omitted),
                           item.siteName]
                .compactMap { $0 }.joined(separator: " · "))
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { TagChip(text: $0) }
                    }
                }
            }
        }
    }
}

struct ArticleDetailView: View {
    let item: Item
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailMeta(item: item, tags: tags)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            WebView(html: item.readerHTML ?? "<p>\(item.textContent ?? "")</p>")
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle(item.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let u = item.url, let url = URL(string: u) {
                Link(destination: url) { Image(systemName: "safari") }
                    .accessibilityLabel("Kaynağı Safari'de aç")
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(html, baseURL: nil)
    }
}

struct VideoDetailView: View {
    let item: Item
    let tags: [String]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = item.assetPath {
                    VideoPlayer(player: AVPlayer(url: AssetStore.url(for: p)))
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                DetailMeta(item: item, tags: tags)
                if let t = item.transcript, !t.isEmpty {
                    DetailSection(title: "Konuşma") {
                        Text(t).font(.callout).lineSpacing(3)
                    }
                }
                if let f = item.frameText, !f.isEmpty {
                    DetailSection(title: "Karelerdeki yazı") {
                        Text(f).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle(item.title ?? "Video")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ImageDetailView: View {
    let item: Item
    let tags: [String]
    @State private var similar: [Item] = []
    private let search = SearchService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LocalImage(relative: item.assetPath)
                    .scaledToFit()
                    .zihinCard()
                DetailMeta(item: item, tags: tags)
                if let ocr = item.ocrText, !ocr.isEmpty {
                    DisclosureGroup {
                        Text(ocr)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                            .textSelection(.enabled)
                    } label: {
                        Text("Görseldeki metin")
                            .font(.headline)
                            .fontDesign(.serif)
                            .foregroundStyle(Color.zihinInk)
                    }
                }
                if !similar.isEmpty {
                    DetailSection(title: "Same Vibe") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(similar) { s in
                                    NavigationLink(value: s.id) {
                                        LocalImage(relative: s.assetPath ?? s.posterPath)
                                            .scaledToFill()
                                            .frame(width: 110, height: 110)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle(item.title ?? "Görsel")
        .navigationBarTitleDisplayMode(.inline)
        .task { similar = search.similarImages(to: item.id) }
    }
}

struct NoteDetailView: View {
    let item: Item
    let tags: [String]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailMeta(item: item, tags: tags)
                if let s = item.summary, !s.isEmpty, s != item.textContent {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Color.zihinGold).frame(width: 3)
                        Text(s)
                            .font(.callout)
                            .fontDesign(.serif)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.textContent ?? "")
                    .font(.body)
                    .fontDesign(.serif)
                    .lineSpacing(4)
                    .foregroundStyle(Color.zihinInk)
                    .textSelection(.enabled)
                if let u = item.url, let url = URL(string: u) {
                    Link("Kaynağı aç", destination: url)
                }
            }
            .padding(16)
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle(item.title ?? "Not")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Serif başlıklı bölüm — detail sayfalarının ortak ritmi.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontDesign(.serif)
                .foregroundStyle(Color.zihinInk)
            content
        }
    }
}
