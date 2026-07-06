import SwiftUI

/// Smart Space = kayıtlı arama (spec §9). Dinamik dolar/boşalır.
struct SpacesView: View {
    @State private var spaces: [Space] = []
    @State private var showNew = false
    @State private var name = ""
    @State private var query = ""
    private let repo = ItemRepository()

    var body: some View {
        NavigationStack {
            List {
                ForEach(spaces) { space in
                    NavigationLink(value: space.id) {
                        VStack(alignment: .leading) {
                            Text(space.name).font(.headline)
                            if let q = space.query {
                                Text(q).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? repo.deleteSpace(id: spaces[i].id) }
                    reload()
                }
            }
            .overlay {
                if spaces.isEmpty {
                    ContentUnavailableView("Space yok",
                        systemImage: "folder",
                        description: Text("Bir aramayı space olarak kaydet; eşleşen her şey otomatik burada olur."))
                }
            }
            .navigationTitle("Space'ler")
            .navigationDestination(for: String.self) { id in
                if let space = spaces.first(where: { $0.id == id }) {
                    SpaceItemsView(space: space)
                }
            }
            .toolbar { Button { showNew = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showNew) {
                NavigationStack {
                    Form {
                        TextField("Ad (ör. Tipografi)", text: $name)
                        TextField("Arama sorgusu (ör. font tasarım)", text: $query)
                    }
                    .navigationTitle("Yeni Space")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Kaydet") {
                                try? repo.saveSpace(Space(name: name, isSmart: true, query: query))
                                name = ""; query = ""; showNew = false
                                reload()
                            }.disabled(name.isEmpty || query.isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .task { reload() }
        }
    }

    private func reload() { spaces = (try? repo.spaces()) ?? [] }
}

struct SpaceItemsView: View {
    let space: Space
    @State private var items: [Item] = []
    private let search = SearchService()
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(value: item.id) { CardView(item: item) }
                        .buttonStyle(.plain)
                }
            }.padding(12)
        }
        .navigationTitle(space.name)
        .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
        .task { items = await search.search(space.query ?? "") }
    }
}
