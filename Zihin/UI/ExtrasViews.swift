import SwiftUI

/// Serendipity (spec §9): rastgele yeniden gösterim, keep/forget.
struct SerendipityView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var deck: [Item] = []
    private let repo = ItemRepository()

    var body: some View {
        NavigationStack {
            VStack {
                if let item = deck.first {
                    NavigationLink(value: item.id) {
                        CardView(item: item)
                            .frame(maxWidth: 320)
                            .padding()
                    }.buttonStyle(.plain)
                    HStack(spacing: 40) {
                        Button {
                            store.forget(item); advance()
                        } label: {
                            Label("Unut", systemImage: "trash")
                        }.tint(.red)
                        Button {
                            store.keep(item); advance()
                        } label: {
                            Label("Tut", systemImage: "heart")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ContentUnavailableView("Bugünlük bu kadar",
                        systemImage: "sparkles",
                        description: Text("Yarın yeni rastgele kartlar seni bekliyor."))
                }
            }
            .navigationTitle("Keşfet")
            .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
            .task { if deck.isEmpty { deck = (try? repo.randomItems(10)) ?? [] } }
            .toolbar {
                Button {
                    deck = (try? repo.randomItems(10)) ?? []
                } label: { Image(systemName: "shuffle") }
            }
        }
    }

    private func advance() { if !deck.isEmpty { deck.removeFirst() } }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Gizlilik") {
                    Text("Tüm analiz (OCR, etiketleme, arama) cihazında çalışır. Hiçbir içerik buluttaki bir yapay zekâya gönderilmez.")
                        .font(.callout)
                }
                Section("İpucu: Video analizi") {
                    Text("Linkle paylaşılan videolarda kapak + açıklama analiz edilir. Tam analiz (karelerdeki yazı + konuşma metni) istersen videoyu ekran kaydet ve Photos'tan paylaş — video asla internetten indirilmez.")
                        .font(.callout)
                }
                Section {
                    LabeledContent("Sürüm", value: Bundle.main
                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
                }
            }
            .navigationTitle("Ayarlar")
        }
    }
}
