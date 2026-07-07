import SwiftUI

/// İlk açılış (Faz 4): 3 sayfa — değer önerisi, gizlilik sözü, nasıl başlanır.
/// İzin diyalogları burada İSTENMEZ; ilgili özellik ilk kullanıldığında sorulur.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    var body: some View {
        VStack {
            TabView(selection: $page) {
                OnboardPage(icon: "sparkles", iconColor: .zihinGold,
                    title: "Kaydet ve unut",
                    text: "Not, görsel, link, video, PDF —\ntek dokunuşla zihnine düşer.\nKlasör yok, düzenleme derdi yok.")
                    .tag(0)
                OnboardPage(icon: "lock.shield", iconColor: .zihinViolet,
                    title: "Her şey cihazında",
                    text: "Etiketleme, metin tanıma ve arama\ntelefonunda çalışır. Hiçbir içerik\nbuluttaki bir yapay zekâya gitmez.")
                    .tag(1)
                OnboardPage(icon: "square.and.arrow.up", iconColor: .zihinGold,
                    title: "Paylaşarak başla",
                    text: "Safari'de ya da Photos'ta paylaş\nmenüsünden Zihin'i seç.\nAradığında, hatırladığın her şeyle bulursun.")
                    .tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 { withAnimation { page += 1 } } else { onDone() }
            } label: {
                Text(page < 2 ? "Devam" : "Zihnini kurmaya başla")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(Color.zihinPaper.ignoresSafeArea())
    }
}

private struct OnboardPage: View {
    let icon: String
    let iconColor: Color
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .fontDesign(.serif)
                .foregroundStyle(Color.zihinInk)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(32)
    }
}
