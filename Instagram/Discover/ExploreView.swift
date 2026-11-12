import SwiftUI

struct ExploreView: View {
    let model: ExploreModel

    var body: some View {
        ScrollView {
            MediaGrid(browser: model.browser, minTile: 210)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            if model.isLoading, !model.browser.items.isEmpty { Spinner().padding(24) }
        }
        .scrollIndicators(.never)
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
        .animation(.easeOut(duration: 0.16), value: model.browser.opened == nil)
        .task { await model.loadIfNeeded() }
    }
}
