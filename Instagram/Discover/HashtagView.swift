import SwiftUI

/// A hashtag's page: a header with its post count over a grid of its top posts.
struct HashtagView: View {
    let model: HashtagModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header.frame(maxWidth: 1000)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top posts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FeedGrid(feed: model.feed, empty: ("number", "No posts for #\(model.name)"))
                }
                .frame(maxWidth: 1000)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .overlay { BrowserLightbox(browser: model.feed.browser) }
        .task { await model.start() }
    }

    private var header: some View {
        HStack(spacing: 36) {
            ZStack {
                if let cover = model.feed.browser.items.first?.image(minWidth: 300) {
                    RemoteImage(url: cover, contentMode: .fill)
                } else {
                    Theme.placeholder
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
            .padding(5)
            VStack(alignment: .leading, spacing: 10) {
                Text("#" + model.name)
                    .font(.system(size: 26, weight: .semibold))
                    .textSelection(.enabled)
                if let n = model.info?.mediaCount {
                    HStack(spacing: 4) {
                        Text(n >= 10_000 ? n.compact : n.formatted()).font(.system(size: 15, weight: .semibold))
                        Text(n == 1 ? "post" : "posts").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                if let url = URL(string: "https://www.instagram.com/explore/tags/\(model.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.name)/") {
                    ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                        .padding(.leading, -8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }
}
