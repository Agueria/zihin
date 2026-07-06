import SwiftUI
import WebKit
import AVKit

struct DetailRouter: View {
    let itemId: String
    private let repo = ItemRepository()
    var body: some View {
        if let item = try? repo.item(id: itemId) {
            switch item.type {
            case .link where item.readerHTML != nil: ArticleDetailView(item: item)
            case .video: VideoDetailView(item: item)
            case .image: ImageDetailView(item: item)
            default: NoteDetailView(item: item)
            }
        } else {
            Text("Bulunamadı")
        }
    }
}

struct ArticleDetailView: View {
    let item: Item
    var body: some View {
        WebView(html: item.readerHTML ?? "<p>\(item.textContent ?? "")</p>")
            .navigationTitle(item.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let u = item.url, let url = URL(string: u) {
                    Link(destination: url) { Image(systemName: "safari") }
                }
            }
    }
}

struct WebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(html, baseURL: nil)
    }
}

struct VideoDetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let p = item.assetPath {
                    VideoPlayer(player: AVPlayer(url: AssetStore.url(for: p)))
                        .frame(height: 240)
                }
                if let t = item.transcript, !t.isEmpty {
                    Text("Konuşma").font(.headline)
                    Text(t).font(.callout)
                }
                if let f = item.frameText, !f.isEmpty {
                    Text("Karelerdeki yazı").font(.headline)
                    Text(f).font(.caption)
                }
            }.padding()
        }
        .navigationTitle(item.title ?? "Video")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ImageDetailView: View {
    let item: Item
    @State private var similar: [Item] = []
    private let search = SearchService()

    var body: some View {
        ScrollView {
            LocalImage(relative: item.assetPath).aspectRatio(contentMode: .fit)
            if let ocr = item.ocrText, !ocr.isEmpty {
                Text(ocr).font(.callout).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !similar.isEmpty {
                Text("Same Vibe").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(similar) { s in
                            NavigationLink(value: s.id) {
                                LocalImage(relative: s.assetPath ?? s.posterPath)
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 120, height: 120)
                                    .clipped().cornerRadius(10)
                            }
                        }
                    }.padding(.horizontal)
                }
            }
        }
        .navigationTitle(item.title ?? "Görsel")
        .navigationBarTitleDisplayMode(.inline)
        .task { similar = search.similarImages(to: item.id) }
    }
}

struct NoteDetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = item.summary, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
                Text(item.textContent ?? "").font(.body)
                if let u = item.url, let url = URL(string: u) {
                    Link("Kaynağı aç", destination: url)
                }
            }.padding()
        }
        .navigationTitle(item.title ?? "Not")
        .navigationBarTitleDisplayMode(.inline)
    }
}
