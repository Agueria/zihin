import SwiftUI
import UIKit

// MARK: - Zihin görsel kimliği: "mürekkep, kâğıt, varak"
// Gece mürekkebi (ink) + sıcak kâğıt zemin + altın varak vurgusu (tezhip'ten).
// Etkileşim rengi: menekşe. Başlıklar serif (New York), gövde SF.

extension Color {
    static let zihinInk       = Color(light: 0x1C1B33, dark: 0xEDEAF6)
    static let zihinPaper     = Color(light: 0xFAF7F2, dark: 0x141322)
    static let zihinCard      = Color(light: 0xFFFFFF, dark: 0x232136)
    static let zihinParchment = Color(light: 0xF6EFDD, dark: 0x2B2740)
    static let zihinGold      = Color(light: 0xB8860B, dark: 0xD9B44A)
    static let zihinViolet    = Color(light: 0x5B4FC4, dark: 0x8F84E8)

    private init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Kart stili (tek kaynak: yarıçap 18, katmanlı yumuşak gölge)

struct ZihinCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.zihinCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

extension View {
    func zihinCard() -> some View { modifier(ZihinCardStyle()) }
}

// MARK: - Küçük yapı taşları

/// Eyebrow: bölüm üstü küçük büyük-harf etiket (bilgi taşır: sayı/bağlam).
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(1.4)
            .foregroundStyle(.secondary)
    }
}

struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.zihinViolet.opacity(0.12)))
            .foregroundStyle(Color.zihinViolet)
            .lineLimit(1)
    }
}

/// Basit iki kolonlu masonry: doğal yükseklikler, indeks dağıtımı.
struct MasonryGrid<T: Identifiable, Content: View>: View {
    let items: [T]
    var columns: Int = 2
    var spacing: CGFloat = 14
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: spacing) {
                    ForEach(items.enumerated().filter { $0.offset % columns == col }
                        .map { $0.element }) { item in
                        content(item)
                    }
                }
            }
        }
    }
}

/// Serif navigation bar başlıkları (uygulama genelinde bir kez).
enum ZihinAppearance {
    static func apply() {
        let ink = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xEDEAF6) : UIColor(rgb: 0x1C1B33) }
        if let d = UIFont.systemFont(ofSize: 34, weight: .bold)
            .fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().largeTitleTextAttributes =
                [.font: UIFont(descriptor: d, size: 34), .foregroundColor: ink]
        }
        if let d = UIFont.systemFont(ofSize: 17, weight: .semibold)
            .fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().titleTextAttributes =
                [.font: UIFont(descriptor: d, size: 17), .foregroundColor: ink]
        }
    }
}

extension Date {
    /// Kart altı tarih: "6 Tem" gibi kısa, sakin.
    var zihinShort: String {
        formatted(.dateTime.day().month(.abbreviated))
    }
}
