import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    @State private var activeFilters: [String] = []
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let results = store.searchResults {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 60)
                    } else {
                        MasonryGrid(items: results) { item in
                            NavigationLink(value: Route.item(item.id)) { CardView(item: item) }
                                .buttonStyle(.plain)
                        }
                        .padding(14)
                    }
                } else {
                    SearchIdle(
                        onPick: { term in
                            query = term
                            store.search(term)
                        },
                        activeFilters: activeFilters,
                        onAddFilter: { filter in
                            activeFilters.append(filter)
                            query = buildFilteredQuery()
                            store.search(query)
                        },
                        onClearFilter: { filter in
                            activeFilters.removeAll { $0 == filter }
                            query = buildFilteredQuery()
                            store.search(query)
                        },
                        onClearAll: {
                            activeFilters.removeAll()
                            query = ""
                            store.clearSearch()
                        }
                    )
                }
            }
            .background(Color.zihinPaper.ignoresSafeArea())
            .navigationTitle("Ara")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .item(let id):
                    DetailRouter(itemId: id)
                case .space:
                    EmptyView()
                }
            }
            .searchable(text: $query, prompt: "mavi sneaker, dün, react…")
            .onChange(of: query) { _, q in store.search(q) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters.toggle()
                    } label: {
                        if !activeFilters.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                    .foregroundStyle(.zihinViolet)
                                Text(activeFilters.count)
                                    .font(.caption2.weight(.bold))
                            }
                            .padding(5)
                            .background(.ultraThinMaterial, in: Capsule())
                        } else {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterPicker(
                    activeFilters: activeFilters,
                    onAddFilter: { filter in
                        activeFilters.append(filter)
                        query = buildFilteredQuery()
                        store.search(query)
                    },
                    onClearFilter: { filter in
                        activeFilters.removeAll { $0 == filter }
                        query = buildFilteredQuery()
                        store.search(query)
                    },
                    onClearAll: {
                        activeFilters.removeAll()
                        query = ""
                        store.clearSearch()
                        showFilters = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    private func buildFilteredQuery() -> String {
        var parts = [query] + activeFilters
        return parts.joined(separator: " ")
    }
}

/// Boş arama ekranı: davet + filtreler.
struct SearchIdle: View {
    var onPick: (String) -> Void
    var activeFilters: [String]
    var onAddFilter: (String) -> Void
    var onClearFilter: (String) -> Void
    var onClearAll: () -> Void

    private let colorTerms = ["mavi", "kırmızı", "yeşil", "sarı", "mor", "pembe", "siyah"]
    private let dateTerms = ["bugün", "dün", "hafta"]
    private let typeTerms = ["note", "link", "image", "video", "pdf"]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Ne hatırlıyorsan onu yaz")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.zihinInk)
                Text("Kelime, görseldeki yazı, renk ya da tarih —\nhepsi cihazında aranır.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !activeFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeFilters, id: \.self) { filter in
                            ActiveFilterChip(label: filter, onDismiss: { onClearFilter(filter) })
                        }
                        Button("Tümünü temizle", role: .destructive) { onClearAll() }
                    }
                }
            }
            VStack(spacing: 12) {
                Eyebrow(text: "Renkle ara")
                HStack(spacing: 12) {
                    ForEach(colorTerms, id: \.self) { name in
                        Button { onPick(name) } label: {
                            Circle()
                                .fill(Color.zihinNamed(name))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        }
                        .accessibilityLabel(name)
                    }
                }
                Eyebrow(text: "Zamanla ara")
                HStack(spacing: 8) {
                    ForEach(dateTerms, id: \.self) { term in
                        Button(term) { onPick(term) }
                            .font(.subheadline)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
                Eyebrow(text: "İçerikle ara")
                HStack(spacing: 8) {
                    ForEach(typeTerms, id: \.self) { term in
                        Button(typeLabel(for: term)) {
                            onAddFilter("type:\(term)")
                        }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity)
    }

    private func typeLabel(for term: String) -> String {
        switch term {
        case "note": "📝 Not"
        case "link": "🔗 Link"
        case "image": "🖼 Görsel"
        case "video": "🎬 Video"
        case "pdf": "📄 PDF"
        default: term
        }
    }
}

/// Aktif filtre çipi
struct ActiveFilterChip: View {
    let label: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Filtre seçici paneli (topic / type / in:space)
struct FilterPicker: View {
    @Environment(\.dismiss) private var dismiss
    var activeFilters: [String]
    var onAddFilter: (String) -> Void
    var onClearFilter: (String) -> Void
    var onClearAll: () -> Void

    private let topicChips = [
        "topic:ai", "topic:tech", "topic:design", "topic:science",
        "topic:business", "topic:life", "topic:media", "topic:tools"
    ]
    private let typeChips = [
        "type:note", "type:link", "type:image", "type:video", "type:pdf"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Konu") {
                    ForEach(topicChips, id: \.self) { chip in
                        FilterChip(label: chip, isActive: activeFilters.contains(chip)) {
                            if activeFilters.contains(chip) {
                                onClearFilter(chip)
                            } else {
                                onAddFilter(chip)
                            }
                        }
                    }
                }
                Section("İçerik türü") {
                    ForEach(typeChips, id: \.self) { chip in
                        FilterChip(label: chip, isActive: activeFilters.contains(chip)) {
                            if activeFilters.contains(chip) {
                                onClearFilter(chip)
                            } else {
                                onAddFilter(chip)
                            }
                        }
                    }
                }
                Section("Space") {
                    Text("in:space-name yazarak bir space içinde ara")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("ornek-space") {
                        onAddFilter("in:ornek-space")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filtreler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tamam") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !activeFilters.isEmpty {
                        Button("Temizle", role: .destructive) { onClearAll() }
                    }
                }
            }
        }
    }
}

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button { onTap() } label: {
            HStack {
                Text(label)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.zihinViolet)
                }
            }
            .padding(.vertical, 6)
        }
    }
}
