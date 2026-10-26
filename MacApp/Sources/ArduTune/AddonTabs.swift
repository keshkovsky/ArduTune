import SwiftUI

/// Нижня вкладка Flight Data для сторінок розширень (location: "flight").
struct FlightAddonsTab: View {
    @AppStorage("addons.flight.tab") private var tab = ""
    private var pages: [AddonPage] { AddonManager.shared.pages("flight") }
    var body: some View {
        if pages.isEmpty {
            ContentUnavailableView("Немає сторінок розширень", systemImage: "puzzlepiece", description: Text("Розширення, що додають панелі в Flight Data, з'являться тут. Керування розширеннями: розділ Add-ons."))
        } else {
            let cur = pages.first { $0.id == tab } ?? pages[0]
            VStack(spacing: 6) {
                if pages.count > 1 { TabStrip(selection: Binding(get: { cur.id }, set: { tab = $0 }), tabs: pages.map { ($0.id, $0.title) }).padding(.horizontal, 12).padding(.top, 6) }
                AddonPageView(addonID: String(cur.id.split(separator: "/").first ?? ""), pageID: cur.pageID).id(cur.id)
            }
        }
    }
}
