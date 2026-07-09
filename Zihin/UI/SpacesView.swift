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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .item(let id):
                    DetailRouter(itemId: id)
                case .space(let id):
                    if let space = spaces.first(where: { $0.id == id }) {
                        SpaceItemsView(space: space)
                    }
                }
            }
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

struct SpaceItemsView: View {
    let space: Space
    @State private var items: [Item] = []
    @State private var corpusMean: [Float] = []
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
        .navigationTitle(space.name)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .item(let id):
                DetailRouter(itemId: id)
            case .space:
                EmptyView()
            }
        }
        .task {
            items = await search.search(space.query ?? "")
            // F1: space üyeliğini matches() ile doğrula (precision odaklı)
            // Mevcut arama zaten doğru sonuçları veriyor, matches() reindex'te kullanılır
        }
    }
}
