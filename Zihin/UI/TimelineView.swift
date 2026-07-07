import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showNewNote = false
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.items.isEmpty {
                    EmptyMind()
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "\(store.items.count) kayıt · hepsi cihazında")
                            .padding(.horizontal, 2)
                        MasonryGrid(items: store.items) { item in
                            NavigationLink(value: item.id) { CardView(item: item) }
                                .buttonStyle(.plain)
                                .contextMenu { cardMenu(item) }
                        }
                    }
                    .padding(14)
                }
            }
            .background(Color.zihinPaper.ignoresSafeArea())
            .navigationTitle("Zihin")
            .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
            .toolbar {
                Button { showNewNote = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Yeni not")
            }
            .sheet(isPresented: $showNewNote) {
                NewNoteSheet(text: $noteText) {
                    store.addNote(noteText); noteText = ""; showNewNote = false
                }
            }
            .refreshable { store.reload() }
        }
    }

    @ViewBuilder private func cardMenu(_ item: Item) -> some View {
        Button(item.isPinned ? "Sabitlemeyi kaldır" : "Sabitle", systemImage: "pin") {
            store.togglePin(item)
        }
        if item.status == .failed {
            Button("Yeniden işle", systemImage: "arrow.clockwise") {
                store.retryEnrichment(item)
            }
        }
        Button("Unut", systemImage: "trash", role: .destructive) { store.forget(item) }
    }
}

// MARK: - Kart

struct CardView: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            footer
        }
        .zihinCard()
        .overlay(alignment: .topTrailing) { statusBadge }
        .overlay(alignment: .topLeading) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.zihinGold)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityLabel("Sabitli")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.type {
        case .image:
            LocalImage(relative: item.assetPath).scaledToFit()
        case .video:
            ZStack {
                LocalImage(relative: item.posterPath ?? item.assetPath).scaledToFit()
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                if item.posterPath != nil {
                    LocalImage(relative: item.posterPath).scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(item.siteName ?? item.url ?? "")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.title ?? item.url ?? "")
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.zihinInk)
                    .lineLimit(3)
            }
            .padding(12)
        case .pdf:
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(Color.zihinViolet)
                Text(item.title ?? "PDF")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        case .note, .quote:
            VStack(alignment: .leading, spacing: 6) {
                if item.type == .quote {
                    Text("\u{201C}")
                        .font(.largeTitle)
                        .fontDesign(.serif)
                        .foregroundStyle(Color.zihinGold)
                        .frame(height: 18, alignment: .top)
                }
                Text(item.textContent ?? "")
                    .font(.callout)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.zihinInk)
                    .lineLimit(9)
                    .lineSpacing(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.zihinParchment)
        }
    }

    /// Kart altı: renk noktaları (renkle arama sinyali) + tarih.
    @ViewBuilder private var footer: some View {
        let colors = item.colors.prefix(4)
        if !colors.isEmpty || item.type == .image || item.type == .video {
            HStack(spacing: 5) {
                ForEach(Array(colors), id: \.self) { name in
                    Circle().fill(Color.zihinNamed(name))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                }
                Spacer(minLength: 0)
                Text(item.createdAt.zihinShort)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending, .enriching:
            ProgressView()
                .controlSize(.mini)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
                .accessibilityLabel("İşleniyor")
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
                .accessibilityLabel("İşlenemedi, menüden yeniden dene")
        case .ready:
            EmptyView()
        }
    }
}

/// App Group asset'i, doğal oranıyla.
struct LocalImage: View {
    let relative: String?
    var body: some View {
        if let relative,
           let ui = UIImage(contentsOfFile: AssetStore.url(for: relative).path) {
            Image(uiImage: ui).resizable()
        } else {
            RoundedRectangle(cornerRadius: 0)
                .fill(.gray.opacity(0.12))
                .frame(height: 120)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }
}

struct EmptyMind: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.zihinGold)
            Text("Zihnin henüz boş")
                .font(.title2.weight(.semibold))
                .fontDesign(.serif)
                .foregroundStyle(Color.zihinInk)
            Text("Safari'den bir yazı, Photos'tan bir görsel paylaş —\nya da + ile ilk notunu bırak.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}

struct NewNoteSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .fontDesign(.serif)
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(Color.zihinParchment)
                .navigationTitle("Yeni Not")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kaydet", action: onSave)
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// TR renk adı -> SwiftUI rengi (kart altı noktalar + arama çipleri).
extension Color {
    static func zihinNamed(_ name: String) -> Color {
        switch name {
        case "siyah": .black
        case "beyaz": .white
        case "gri": .gray
        case "kırmızı": .red
        case "turuncu": .orange
        case "sarı": .yellow
        case "yeşil": .green
        case "mavi": .blue
        case "lacivert": Color(red: 0.08, green: 0.12, blue: 0.43)
        case "mor": .purple
        case "pembe": .pink
        case "kahverengi": .brown
        case "bej": Color(red: 0.88, green: 0.78, blue: 0.63)
        case "turkuaz": .teal
        default: .gray
        }
    }
}
