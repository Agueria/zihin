import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showNewNote = false
    @State private var noteText = ""

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.items.isEmpty {
                    ContentUnavailableView("Zihnin boş",
                        systemImage: "brain",
                        description: Text("Safari veya Photos'tan paylaş, ya da + ile not ekle."))
                        .padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.items) { item in
                        NavigationLink(value: item.id) { CardView(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(item.isPinned ? "Sabitlemeyi kaldır" : "Sabitle",
                                       systemImage: "pin") { store.togglePin(item) }
                                if item.status == .failed {
                                    Button("Yeniden işle", systemImage: "arrow.clockwise") {
                                        store.retryEnrichment(item)
                                    }
                                }
                                Button("Unut", systemImage: "trash", role: .destructive) {
                                    store.forget(item)
                                }
                            }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Zihin")
            .navigationDestination(for: String.self) { id in DetailRouter(itemId: id) }
            .toolbar {
                Button { showNewNote = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showNewNote) {
                NewNoteSheet(text: $noteText) {
                    store.addNote(noteText); noteText = ""; showNewNote = false
                }
            }
            .refreshable { store.reload() }
        }
    }
}

struct CardView: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            HStack(spacing: 6) {
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                if item.status == .pending || item.status == .enriching {
                    ProgressView().controlSize(.mini)
                } else if item.status == .failed {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.type {
        case .image:
            LocalImage(relative: item.assetPath)
                .aspectRatio(contentMode: .fill)
                .frame(height: 160).clipped().cornerRadius(12)
        case .video:
            ZStack(alignment: .bottomLeading) {
                LocalImage(relative: item.posterPath ?? item.assetPath)
                    .aspectRatio(contentMode: .fill).frame(height: 160).clipped()
                Image(systemName: "play.circle.fill").font(.title).padding(6)
                    .foregroundStyle(.white)
            }.cornerRadius(12)
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                if item.posterPath != nil {
                    LocalImage(relative: item.posterPath)
                        .aspectRatio(contentMode: .fill).frame(height: 110).clipped()
                        .cornerRadius(8)
                }
                Text(item.title ?? item.url ?? "").font(.subheadline).lineLimit(2)
                Text(item.siteName ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.08)).cornerRadius(12)
        case .pdf:
            HStack {
                Image(systemName: "doc.richtext")
                Text(item.title ?? "PDF").lineLimit(2)
            }
            .padding().frame(maxWidth: .infinity, minHeight: 120)
            .background(.gray.opacity(0.08)).cornerRadius(12)
        case .note, .quote:
            Text(item.textContent ?? "").font(.callout).lineLimit(8)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.12)).cornerRadius(12)
        }
    }
}

/// App Group asset'ini gösterir.
struct LocalImage: View {
    let relative: String?
    var body: some View {
        if let relative,
           let ui = UIImage(contentsOfFile: AssetStore.url(for: relative).path) {
            Image(uiImage: ui).resizable()
        } else {
            Rectangle().fill(.gray.opacity(0.15))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

struct NewNoteSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Yeni Not")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kaydet", action: onSave)
                    }
                }
        }
    }
}
