import SwiftUI
import UniformTypeIdentifiers

// MARK: - Keşfet (Serendipity) — imza an: "altın varak" deste

struct SerendipityView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var deck: [Item] = []
    private let repo = ItemRepository()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Eyebrow(text: deck.isEmpty ? "Günün hatırlatmaları"
                        : "Günün hatırlatmaları · \(deck.count) kaldı")
                if deck.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.zihinGold)
                        Text("Bugünlük bu kadar")
                            .font(.title3.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(Color.zihinInk)
                        Text("Kaydettiklerin unutulmasın diye\narada bir buraya düşer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    Spacer()
                    ZStack {
                        // Arkadaki kartlar: hafif dönük, sessiz
                        ForEach(Array(deck.prefix(3).enumerated().reversed()),
                                id: \.element.id) { index, item in
                            if index == 0 {
                                NavigationLink(value: Route.item(item.id)) {
                                    CardView(item: item).frame(maxWidth: 300)
                                }
                                .buttonStyle(.plain)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                            } else {
                                CardView(item: item)
                                    .frame(maxWidth: 300)
                                    .rotationEffect(.degrees(Double(index) * 2.5))
                                    .offset(y: CGFloat(index) * 6)
                                    .opacity(0.55)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .animation(.spring(duration: 0.35), value: deck.map(\.id))
                    Spacer()
                    if let top = deck.first {
                        HStack(spacing: 28) {
                            Button {
                                store.forget(top); advance()
                            } label: {
                                Label("Unut", systemImage: "trash")
                                    .frame(minWidth: 100)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.red)

                            Button {
                                store.keep(top); advance()
                            } label: {
                                Label("Tut", systemImage: "heart.fill")
                                    .frame(minWidth: 100)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .tint(Color.zihinGold)
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.zihinPaper.ignoresSafeArea())
            .navigationTitle("Keşfet")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .item(let id):
                    DetailRouter(itemId: id)
                case .space:
                    EmptyView()
                }
            }
            .toolbar {
                Button {
                    deck = (try? repo.randomItems(10)) ?? []
                } label: { Image(systemName: "shuffle") }
                .accessibilityLabel("Yeni deste")
            }
            .task { if deck.isEmpty { deck = (try? repo.randomItems(10)) ?? [] } }
        }
    }

    private func advance() {
        guard !deck.isEmpty else { return }
        deck.removeFirst()
    }
}

// MARK: - Ayarlar

struct SettingsView: View {
    @AppStorage("iCloudSync") private var iCloudSync = false
    @State private var syncing = false
    @State private var showFolderPicker = false
    @State private var exportMessage: String?
    @State private var reindexing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $iCloudSync) {
                        Label("iCloud eşitleme", systemImage: "icloud")
                    }
                    Button {
                        syncing = true
                        Task {
                            await CloudKitSyncService.shared.sync()
                            syncing = false
                        }
                    } label: {
                        HStack {
                            Label("Şimdi eşitle", systemImage: "arrow.triangle.2.circlepath")
                            if syncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!iCloudSync || syncing)
                } header: {
                    Text("Eşitleme")
                } footer: {
                    Text("Veri senin iCloud'unda (private database) durur; bize hiçbir şey gelmez. Görsel/video dosyaları v1.1'de eşitlenecek.")
                }

                Section("İndeksleme") {
                    Button {
                        reindexing = true
                        Task {
                            await EnrichmentQueue.shared.reindex()
                            reindexing = false
                        }
                    } label: {
                        HStack {
                            Label("Yeniden indeksle", systemImage: "arrow.clockwise")
                            if reindexing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(reindexing)
                } header: {
                    Text("İçerik işleme")
                } footer: {
                    Text("Tüm kayıtların embedding'leri sıfırlanır ve yeniden üretilir. Bu işlem uzun sürebilir.")
                }

                Section("Gelişmiş model") {
                    Text("~80 MB contrastive encoder modeli — daha iyi ayrışma, merkezlemeye ihtiyaç duymaz.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        reindexing = true
                        Task {
                            await AdvancedModelDownloader.downloadIfNeeded()
                            reindexing = false
                        }
                    } label: {
                        HStack {
                            Label("Gelişmiş modeli indir", systemImage: "arrow.down.circle")
                            if reindexing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(reindexing)
                } header: {
                    Text("Model ayarları")
                } footer: {
                    Text("Model değiştiğinde tüm kayıtlar otomatik olarak yeniden işlenir. İndirme sırasında internet bağlantısı gerekir.")
                }

                Section {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Obsidian / Markdown'a aktar", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Verin senindir")
                } footer: {
                    Text("Tüm kayıtlar frontmatter'lı .md dosyaları olarak seçtiğin klasöre (örn. Obsidian vault) yazılır.")
                }

                Section("Gizlilik") {
                    Label {
                        Text("Tüm analiz — OCR, etiketleme, özet, arama — cihazında çalışır. Hiçbir içerik buluttaki bir yapay zekâya gönderilmez.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Color.zihinViolet)
                    }
                }

                Section("İpucu: Video analizi") {
                    Text("Linkle paylaşılan videolarda kapak + açıklama analiz edilir. Tam analiz (karelerdeki yazı + konuşma) istersen videoyu ekran kaydet ve Photos'tan paylaş — video asla internetten indirilmez.")
                        .font(.callout)
                }

                Section {
                    LabeledContent("Sürüm", value: Bundle.main
                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.zihinPaper.ignoresSafeArea())
            .navigationTitle("Ayarlar")
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder):
                    do {
                        let n = try ObsidianExporter.export(to: folder)
                        exportMessage = "\(n) kayıt Markdown olarak aktarıldı."
                    } catch {
                        exportMessage = "Aktarım başarısız: klasöre erişilemedi."
                    }
                case .failure:
                    break
                }
            }
            .alert("Dışa aktarım", isPresented: Binding(
                get: { exportMessage != nil },
                set: { if !$0 { exportMessage = nil } })) {
                Button("Tamam") { exportMessage = nil }
            } message: {
                Text(exportMessage ?? "")
            }
        }
    }
}
