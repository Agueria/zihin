import SwiftUI

/// Zihin Ağı (E2): kayıtların otomatik bağlantı haritası.
/// Menekşe kenar = anlam bağı (embedding), altın kenar = ortak etiket.
/// Sürükle: kaydır · iki parmak: yakınlaştır · düğüme dokun: önizleme + git.
struct GraphView: View {
    @State private var data: KnowledgeGraphData?
    @State private var building = true
    @State private var selected: GraphNode?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Group {
            if building {
                ProgressView("Bağlantılar hesaplanıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let data, !data.nodes.isEmpty {
                canvas(data)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.zihinViolet)
                    Text("Henüz bağ yok")
                        .font(.title3.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(Color.zihinInk)
                    Text("Kaydettikçe benzer içerikler ve ortak etiketler\nburada kendiliğinden birbirine bağlanır.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.zihinPaper.ignoresSafeArea())
        .navigationTitle("Zihin Ağı")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let built = try? KnowledgeGraph.build()
            data = built
            building = false
        }
    }

    // MARK: Çizim

    private func canvas(_ data: KnowledgeGraphData) -> some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, _ in
                    var pos: [String: CGPoint] = [:]
                    for n in data.nodes { pos[n.id] = screenPoint(n, in: size) }

                    for e in data.edges {
                        guard let pa = pos[e.a], let pb = pos[e.b] else { continue }
                        var path = Path()
                        path.move(to: pa)
                        path.addLine(to: pb)
                        let color: Color = e.kind == .semantic
                            ? .zihinViolet.opacity(0.20 + e.weight * 0.25)
                            : .zihinGold.opacity(0.25 + e.weight * 0.25)
                        ctx.stroke(path, with: .color(color),
                                   lineWidth: 0.6 + e.weight * 1.4)
                    }
                    for n in data.nodes {
                        guard let p = pos[n.id] else { continue }
                        let r = 4.0 + Double(min(8, n.degree))
                        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                        if n.id == selected?.id {
                            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                       with: .color(.zihinGold), lineWidth: 2)
                        }
                        ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor(n.type)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: baseOffset.width + v.translation.width,
                                            height: baseOffset.height + v.translation.height)
                        }
                        .onEnded { _ in baseOffset = offset }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(0.5, min(4, baseScale * v)) }
                        .onEnded { _ in baseScale = scale }
                )
                .onTapGesture(coordinateSpace: .local) { loc in
                    selected = nearestNode(to: loc, in: data, size: size)
                }

                VStack {
                    legend(data)
                    Spacer()
                    if let node = selected { selectionCard(node) }
                }
                .padding(12)
            }
        }
    }

    private func screenPoint(_ n: GraphNode, in size: CGSize) -> CGPoint {
        CGPoint(x: n.x * size.width * scale + offset.width,
                y: n.y * size.height * scale + offset.height)
    }

    private func nearestNode(to loc: CGPoint, in data: KnowledgeGraphData,
                             size: CGSize) -> GraphNode? {
        var best: (GraphNode, CGFloat)?
        for n in data.nodes {
            let p = screenPoint(n, in: size)
            let d = hypot(p.x - loc.x, p.y - loc.y)
            if d < 28, d < (best?.1 ?? .infinity) { best = (n, d) }
        }
        return best?.0
    }

    private func nodeColor(_ type: ItemType) -> Color {
        switch type {
        case .note, .quote: .zihinGold
        case .image: .blue
        case .link: .zihinViolet
        case .video: .pink
        case .pdf: .brown
        }
    }

    // MARK: Katmanlar

    private func legend(_ data: KnowledgeGraphData) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(Color.zihinViolet.opacity(0.5))
                    .frame(width: 18, height: 3)
                Text("anlam bağı")
            }
            HStack(spacing: 5) {
                Capsule().fill(Color.zihinGold.opacity(0.6))
                    .frame(width: 18, height: 3)
                Text("ortak etiket")
            }
            Spacer()
            if data.isolatedCount > 0 {
                Text("+\(data.isolatedCount) bağsız kayıt gizli")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func selectionCard(_ node: GraphNode) -> some View {
        HStack(spacing: 12) {
            Circle().fill(nodeColor(node.type)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.zihinInk)
                    .lineLimit(2)
                Text("\(node.degree) bağlantı")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink(value: node.id) {
                Text("Aç")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(12)
        .zihinCard()
    }
}
