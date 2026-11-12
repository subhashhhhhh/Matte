import SwiftUI

struct ExploreView: View {
    @State private var flight = PhotoFlight()
    let model: ExploreModel

    var body: some View {
        ScrollView {
            MediaGrid(browser: model.browser, minTile: 210)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            if model.isLoading, !model.browser.items.isEmpty { Spinner().padding(24) }
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 60 } action: { model.browser.scrolledAway = $1 }
        .overlay {
            if model.browser.items.isEmpty {
                if model.loadFailed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load Explore", actionTitle: "Try Again") {
                        Task { await model.refresh() }
                    }
                } else {
                    Spinner(size: 22)
                }
            }
        }
        .overlay { BrowserLightbox(browser: model.browser) }
        .photoFlightHost(flight)
        .task { await model.loadIfNeeded() }
    }
}
