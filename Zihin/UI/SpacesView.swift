import SwiftUI

/// Smart Space = kayıtlı arama (spec §9). v2: navigasyon `Route` ile (§4.5).
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
                    NavigationLink(value: Route.space(space.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(space.name)
                                .font(.headline)
                                .fontDesign(.serif)
                                .foregroundStyle(Color.zihinInk)
                            if let q = space.query {
                                Text("“\(q)” aramasıyla eşleşenler")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { idx in
                    for i in idx { try? repo.deleteSpace(id: spaces[i].id) }
                    reload()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.zihinPaper.ignoresSafeArea())
            .overlay {
                if spaces.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.zihinViolet)
                        Text("Henüz space yok")
                            .font(.title3.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(Color.zihinInk)
                        Text("Bir aramayı kaydet; eşleşen her kayıt\notomatik olarak burada toplanır.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .navigationTitle("Space'ler")
            .zihinRoutes()
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Yeni space")
            }
            .sheet(isPresented: $showNew) {
                NavigationStack {
                    Form {
                        TextField("Ad (ör. Tipografi)", text: $name)
                        TextField("Arama sorgusu (ör. font tasarım)", text: $query)
                    }
                    .navigationTitle("Yeni Space")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Kaydet") {
                                try? repo.saveSpace(Space(name: name, isSmart: true, query: query))
                                name = ""; query = ""; showNew = false
                                reload()
                            }
                            .disabled(name.isEmpty || query.isEmpty)
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

/// Space içeriği. v2 (§4.5): `spaceId` ile yüklenir; item'lar `Route.item` ile açılır.
struct SpaceItemsView: View {
    let spaceId: String
    @State private var space: Space?
    @State private var items: [Item] = []
    private let repo = ItemRepository()
    private let search = SearchService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "\(items.count) eşleşen kayıt")
                MasonryGrid(items: items) { item in
                    NavigationLink(value: Route.item(item.id)) { CardView(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle(space?.name ?? "Space")
        .task {
            space = (try? repo.spaces())?.first { $0.id == spaceId }
            // TODO(F1.2): materyalize item_space üyeliğinden oku (matches() ⟂ search()).
            // Şimdilik kayıtlı sorguyla dolduruluyor.
            items = await search.search(space?.query ?? "")
        }
    }
}
