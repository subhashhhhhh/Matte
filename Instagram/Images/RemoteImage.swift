import SwiftUI

/// Shows a remote image, decoded at exactly the pixel size it's displayed at.
struct RemoteImage: View {
    let url: URL?
    /// Shown if `url` fails to load.
    var fallback: URL? = nil
    var contentMode: ContentMode = .fill
    /// An already-decoded image to show until `url` loads (a photo handed over by the flight).
    var initial: CGImage? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Theme.placeholder)
                // A memory-cache hit shows on the first frame (no grey flash, no fade).
                if let image = image ?? initial ?? cachedHit(geo.size) {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .task(id: TaskKey(url: url, side: bucket(geo.size))) {
                await load(side: bucket(geo.size))
            }
        }
    }

    private func cachedHit(_ size: CGSize) -> CGImage? {
        guard let url else { return nil }
        let side = bucket(size)
        return side > 0 ? ImagePipeline.shared.cachedImage(for: url, maxPixel: side) : nil
    }

    /// Pixel size rounded up to 64px steps, so live window resizing doesn't refetch constantly.
    private func bucket(_ size: CGSize) -> Int {
        let px = Int(max(size.width, size.height) * displayScale)
        return px <= 0 ? 0 : ((px + 63) / 64) * 64
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let side: Int
    }

    private func load(side: Int) async {
        guard let url, side > 0 else { image = nil; return }
        if loadedURL != url { image = nil }
        if let hit = ImagePipeline.shared.cachedImage(for: url, maxPixel: side) {
            image = hit
            loadedURL = url
            return
        }
        var result = await ImagePipeline.shared.image(for: url, maxPixel: side)
        if result == nil, let fallback, !Task.isCancelled {
            result = await ImagePipeline.shared.image(for: fallback, maxPixel: side)
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { image = result }
        loadedURL = url
    }
}
