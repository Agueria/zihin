import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""

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
                    SearchIdle { term in
                        query = term
                        store.search(term)
                    }
                }
            }
            .background(Color.zihinPaper.ignoresSafeArea())
            .navigationTitle("Ara")
            .zihinRoutes()
            .searchable(text: $query, prompt: "mavi sneaker, dün, react…")
            .onChange(of: query) { _, q in store.search(q) }
        }
    }
}

/// Boş arama ekranı: davet + tek dokunuşla renk/tarih filtreleri.
struct SearchIdle: View {
    var onPick: (String) -> Void
    private let colorTerms = ["mavi", "kırmızı", "yeşil", "sarı", "mor", "pembe", "siyah"]
    private let dateTerms = ["bugün", "dün", "hafta"]

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
            }
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity)
    }
}
