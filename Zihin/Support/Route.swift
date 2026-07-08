import SwiftUI

/// Tek tip yönlendirme (spec §4.5). String yerine `Route` → `navigationDestination`
/// tip çakışması TİP DÜZEYİNDE imkânsız. Eskiden aynı NavigationStack içinde iki ayrı
/// `String` destination kaydediliyordu; dıştaki kazanıp item id'siyle boş view push
/// ediyordu ("space'te nota tıklayınca boş ekran" hatası).
enum Route: Hashable {
    case item(String)      // item id
    case space(String)     // space id
}

extension View {
    /// Her NavigationStack kökünde BİR KEZ çağrılır: item + space hedeflerini kaydeder.
    func zihinRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .item(let id):  DetailRouter(itemId: id)
            case .space(let id): SpaceItemsView(spaceId: id)
            }
        }
    }
}
