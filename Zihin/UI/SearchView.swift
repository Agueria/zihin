import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let results = store.searchResults {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 60)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { item in
                            NavigationLink(value: item.id) { CardView(item: item) }
                                .buttonStyle(.plain)
                        }
                    }.padding(12)
                } else {
                    VStack(spacing: 8) {
                        Text("Ne hatırlıyorsan onu yaz")
                            .font(.headline)
                        Text("Kelime, renk (\"mavi\"), tarih (\"dün\"), görseldeki yazı…")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 60)
                }
            }
            .navigationTitle("Ara")
            .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
            .searchable(text: $query, prompt: "mavi sneaker, dün, react…")
            .onChange(of: query) { _, q in store.search(q) }
            .onSubmit(of: .search) { store.search(query) }
        }
    }
}
