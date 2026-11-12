import SwiftUI

/// Posts as an even grid of 3:4 tiles (Instagram's profile and Explore shape). Hovering shows
/// the counts and previews a video silently; clicking opens the post large over the page.
struct MediaGrid: View {
    let browser: MediaBrowser
    var minTile: CGFloat = 200

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile), spacing: 4)], spacing: 4) {
            ForEach(Array(browser.items.enumerated()), id: \.element.pk) { i, media in
                GridTile(media: media, isPreviewing: browser.playing == media.pk) { on in
                    if on { browser.playing = media.pk } else if browser.playing == media.pk { browser.playing = nil }
                }
                .onTapGesture { browser.open(at: i) }
                .contextMenu { PostMenu(media: media) { browser.open(at: i) } }
                .onAppear { browser.appeared(i) }
            }
        }
    }
}

struct GridTile: View {
    let media: Media
    var isPreviewing: Bool
    var setPreviewing: (Bool) -> Void
    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var previewVideo: URL? {
        let source = media.children.first ?? media
        return source.isVideo ? source.video(minWidth: 400) : nil
    }

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4, contentMode: .fit)
            .overlay {
                RemoteImage(url: media.image(minWidth: 480), contentMode: .fill)
                if isPreviewing, let url = previewVideo { HoverPreview(url: url) }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Group {
                    if media.children.count > 1 {
                        Image(systemName: "square.on.square.fill")
                    } else if media.productType == "clips" {
                        IGGlyph(icon: .reelsFilled, size: 16)
                    } else if media.isVideo {
                        Image(systemName: "play.fill")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(8)
            }
            .overlay {
                if hovering, !isPreviewing {
                    ZStack {
                        Color.black.opacity(0.35)
                        HStack(spacing: 18) {
                            if !media.countsHidden, let n = media.likeCount, n > 0 {
                                HStack(spacing: 5) { IGGlyph(icon: .heartFilled, size: 18); Text(n.compact) }
                            }
                            if let n = media.commentCount, n > 0 {
                                HStack(spacing: 5) { IGGlyph(icon: .comment, size: 18); Text(n.compact) }
                            }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                hoverTask?.cancel()
                guard previewVideo != nil else { return }
                if inside {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { setPreviewing(true) }
                    }
                } else if isPreviewing {
                    setPreviewing(false)
                }
            }
    }
}

/// The opened post over a grid page, stepping through the grid.
struct BrowserLightbox: View {
    let browser: MediaBrowser

    var body: some View {
        if let opened = browser.opened {
            PostLightbox(model: opened,
                         canPrevious: (browser.openedIndex ?? 0) > 0,
                         canNext: (browser.openedIndex ?? 0) < browser.items.count - 1,
                         step: { browser.step($0) }, close: { browser.closeOpened() })
                .transition(.opacity)
        }
    }
}
