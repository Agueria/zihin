import SwiftUI

@main
struct ZihinApp: App {
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("iCloudSync") private var iCloudSync = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    init() { ZihinAppearance.apply() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.zihinViolet)
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { hasOnboarded = !$0 })) {
                    OnboardingView { hasOnboarded = true }
                }
                .task { await refresh() }
                .onChange(of: scenePhase) { _, phase in
                    // Extension'dan dönüşte pending item'ları işle (spec §3.2)
                    if phase == .active { Task { await refresh() } }
                }
        }
    }

    @MainActor
    private func refresh() async {
        store.reload()
        await EnrichmentQueue.shared.run()
        store.reload()
        if iCloudSync {
            await CloudKitSyncService.shared.sync()
            store.reload()
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var items: [Item] = []
    @Published var searchResults: [Item]? = nil
    private let repo = ItemRepository()
    private let searchService = SearchService()

    func reload() { items = (try? repo.timeline()) ?? [] }

    func search(_ q: String) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = nil; return }
        Task {
            let r = await searchService.search(q)
            self.searchResults = r
        }
    }
    func clearSearch() { searchResults = nil }

    func addNote(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            _ = try? IngestionService.capture(.text(text))
            await EnrichmentQueue.shared.run()
            self.reload()
        }
    }
    func togglePin(_ item: Item) {
        try? repo.setPinned(!item.isPinned, id: item.id); reload()
    }
    func forget(_ item: Item) {
        try? repo.setForgotten(true, id: item.id); reload()
    }
    func keep(_ item: Item) {
        try? repo.setForgotten(false, id: item.id); reload()
    }
    /// failed item için manuel yeniden deneme
    func retryEnrichment(_ item: Item) {
        try? repo.setStatus(.pending, id: item.id)
        Task { await EnrichmentQueue.shared.run(); self.reload() }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TimelineView().tabItem { Label("Zihin", systemImage: "square.grid.2x2") }
            SearchView().tabItem { Label("Ara", systemImage: "magnifyingglass") }
            SpacesView().tabItem { Label("Space'ler", systemImage: "square.stack") }
            SerendipityView().tabItem { Label("Keşfet", systemImage: "sparkles") }
            SettingsView().tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
    }
}
