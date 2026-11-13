import Foundation
import ImageIO
import CoreGraphics
import OSLog

/// Loads remote images decoded straight to their display size.
///
/// A timeline is mostly avatars and photos, so this is where memory is won or lost:
/// - images are decoded with ImageIO's thumbnailing, never at full resolution
/// - decoded bitmaps live in a cost-limited cache (evicted under pressure)
/// - downloaded bytes go to a disk cache only, never an in-memory one
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    /// Decoded bitmaps by size bucket and stable key. NSCache is thread-safe, so views can check
    /// it synchronously (`cachedImage`) and show a hit on their first frame, without a fade.
    nonisolated(unsafe) private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var downloads: [String: Task<Data?, Never>] = [:]
    private var prefetchQueue: [URL] = []
    private var prefetching = 0
    private let disk: URL
    private let diskBudget: Int
    /// Bytes written since the last trim: the disk cache is trimmed as it grows, not only at launch.
    private var writtenSinceTrim = 0
    private let log = Logger(subsystem: "com.subhash.Matte", category: "Images")

    init(memoryBudgetMB: Int = 96, diskBudgetMB: Int = 400) {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
        cache.totalCostLimit = memoryBudgetMB << 20
        disk = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.subhash.Matte/img", directoryHint: .isDirectory)
        diskBudget = diskBudgetMB << 20
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let dir = disk, budget = diskBudget
        Task.detached(priority: .background) { Self.trim(dir, to: budget) }
    }

    /// Instagram's image links carry a signature that changes on every API response; the same
    /// picture at the same size keeps its path and `stp` (size/crop) parameter. Keying on those
    /// lets a re-fetched feed hit the cache instead of downloading (and fading in) again.
    nonisolated static func stableKey(_ url: URL) -> String {
        guard let host = url.host(), host.contains("cdninstagram") || host.contains("fbcdn") || host.contains("fbsbx") else {
            return url.absoluteString
        }
        let stp = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stp" }?.value ?? ""
        return url.path() + "|" + stp
    }

    private nonisolated static func memoryKey(_ url: URL, _ bucket: Int) -> NSString {
        "\(bucket)|\(stableKey(url))" as NSString
    }

    private nonisolated static func bucket(_ maxPixel: Int) -> Int { max(64, ((maxPixel + 63) / 64) * 64) }

    /// A decoded image already in memory, or nil — synchronous, for a view's first frame.
    nonisolated func cachedImage(for url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: Self.memoryKey(url, Self.bucket(maxPixel)))?.image
    }

    /// Returns `url` decoded so its longest side is at most `maxPixel` pixels.
    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        // Bucket sizes so slightly different layouts share cache entries.
        let bucket = Self.bucket(maxPixel)
        let key = Self.memoryKey(url, bucket)
        if let hit = cache.object(forKey: key) { return hit.image }
        if let running = inFlight[key as String] { return await running.value }

        let task = Task<CGImage?, Never> { [weak self] in
            guard let data = await self?.bytes(for: url) else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.downsample(data, maxPixel: bucket) }.value
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Raw bytes (from the disk cache, or downloaded into it), for formats decoded elsewhere.
    func data(for url: URL) async -> Data? { await bytes(for: url) }

    /// Downloads `url` into the disk cache in the background (no decode), so opening it later is
    /// a local read. A few at a time, newest requests first.
    func prefetch(_ urls: [URL]) {
        for url in urls where !url.isFileURL && !FileManager.default.fileExists(atPath: file(for: url).path) {
            prefetchQueue.append(url)
        }
        if prefetchQueue.count > 60 { prefetchQueue.removeFirst(prefetchQueue.count - 60) }
        pump()
    }

    /// Decodes `url` into memory ahead of time (a post you're hovering, the next story).
    func warm(_ url: URL, maxPixel: Int) {
        Task(priority: .utility) { _ = await image(for: url, maxPixel: maxPixel) }
    }

    private func pump() {
        while prefetching < 4, let url = prefetchQueue.popLast() {
            prefetching += 1
            Task(priority: .utility) {
                _ = await bytes(for: url)
                prefetching -= 1
                pump()
            }
        }
    }

    private func file(for url: URL) -> URL {
        disk.appending(path: Self.hash(Self.stableKey(url)))
    }

    private func bytes(for url: URL) async -> Data? {
        // Only downloads are kept on disk; a local file is read where it is.
        if url.isFileURL { return try? Data(contentsOf: url) }
        let path = file(for: url)
        if let data = try? Data(contentsOf: path) { return data }
        let key = Self.stableKey(url)
        if let running = downloads[key] { return await running.value }
        let task = Task<Data?, Never> { [session, log] in
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !data.isEmpty else { return nil }
                try? data.write(to: path, options: .atomic)
                return data
            } catch {
                if !(error is CancellationError) {
                    log.debug("Image failed: \(url.lastPathComponent, privacy: .public) \(error.localizedDescription, privacy: .public)")
                }
                return nil
            }
        }
        downloads[key] = task
        let data = await task.value
        downloads[key] = nil
        if let data {
            writtenSinceTrim += data.count
            if writtenSinceTrim > diskBudget / 5 {
                writtenSinceTrim = 0
                Self.trim(disk, to: diskBudget)
            }
        }
        return data
    }

    func clearMemory() { cache.removeAllObjects() }

    /// Drops decoded images and the on-disk image cache.
    func clearAll() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: disk)
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    }

    /// FNV-1a, hex: a short stable file name for a key.
    private nonisolated static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Keeps the disk cache under budget by deleting the least recently written files.
    private nonisolated static func trim(_ dir: URL, to budget: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > budget else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries where total > budget * 8 / 10 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// NSCache needs a class; CGImage is immutable, so sharing it is safe.
private nonisolated final class CGImageBox: Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
