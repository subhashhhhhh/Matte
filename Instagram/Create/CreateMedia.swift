import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A crop the create sheet offers. instagram.com's crop menu has Original, 1:1, 4:5 and 16:9
/// (`PolarisCreationConstants`); reels and stories also fill a 9:16 phone screen.
nonisolated enum CropShape: String, CaseIterable, Sendable, Identifiable {
    case original, square, portrait, landscape, tall
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .square: "1:1"
        case .portrait: "4:5"
        case .landscape: "16:9"
        case .tall: "9:16"
        }
    }

    /// Width over height; `original` takes the first item's own shape.
    func ratio(original: CGFloat) -> CGFloat {
        switch self {
        case .original: original
        case .square: 1
        case .portrait: 4.0 / 5
        case .landscape: 16.0 / 9
        case .tall: 9.0 / 16
        }
    }
}

/// A picked photo or video, read just enough to lay it out (no pixels held).
nonisolated struct CreateSource: Sendable, Hashable {
    var url: URL
    var isVideo: Bool
    /// Upright size in pixels (EXIF orientation / track transform applied).
    var width: Int
    var height: Int
    var durationMs: Int?

    var aspect: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }
}

/// A file ready to upload.
nonisolated struct PreparedMedia: Sendable, Hashable {
    var file: URL
    var width: Int
    var height: Int
    var durationMs: Int?
    /// A video's cover frame (JPEG), as big as the video.
    var cover: URL?
    var bytes: Int {
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return size(file) + (cover.map(size) ?? 0)
    }
}

/// What the web app does to media before uploading, done locally: photos cropped and
/// re-encoded as JPEG (a canvas `toBlob("image/jpeg")`, quality 0.92) at most 1080 px wide;
/// videos cropped and re-encoded as H.264/AAC MP4, with a JPEG cover from the first frame.
nonisolated enum CreateMedia {
    /// `PolarisCreationConstants` / `PolarisMediaConstants`: files of 5 KB to 1 GB, videos of
    /// 1 s to 20 min (reels), photos between 3:4 and 1.91:1. Story videos: 60 s (Instagram's
    /// story length; the web app has no limit of its own as it doesn't post story videos).
    static let minFileSize = 5_000
    static let maxFileSize = 1_000_000_000
    static let minVideoSeconds = 1.0
    static let maxReelSeconds = 1200.0
    static let maxStorySeconds = 60.0
    static let photoAspects: ClosedRange<CGFloat> = 0.75...1.91
    static let reelAspects: ClosedRange<CGFloat> = (9.0 / 16)...1.91
    static let maxWidth = 1080
    static let maxItems = 20
    static let jpegQuality = 0.92

    enum Problem: LocalizedError {
        case unsupported(String), tooSmall(String), tooLarge(String), unreadable(String), tooShort(String), tooLong(String, Int)
        var errorDescription: String? {
            switch self {
            case .unsupported(let n): "\(n) isn't a photo or video."
            case .tooSmall(let n): "\(n) is too small to post."
            case .tooLarge(let n): "\(n) is larger than Instagram's 1 GB limit."
            case .unreadable(let n): "Matte couldn't read \(n)."
            case .tooShort(let n): "\(n) is shorter than a second."
            case .tooLong(let n, let s): "\(n) is longer than \(s / 60) minutes."
            }
        }
    }

    /// Prepared uploads live here until the post is shared; emptied at launch.
    static let folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Create", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func isPhoto(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    // MARK: Reading

    @concurrent
    static func read(_ url: URL) async throws -> CreateSource {
        let name = url.lastPathComponent
        guard let type = UTType(filenameExtension: url.pathExtension) else { throw Problem.unsupported(name) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < minFileSize { throw Problem.tooSmall(name) }
        if size > maxFileSize { throw Problem.tooLarge(name) }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.unreadable(name) }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let upright = CGRect(origin: .zero, size: natural).applying(transform).size
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite else { throw Problem.unreadable(name) }
            if seconds < minVideoSeconds { throw Problem.tooShort(name) }
            if seconds > maxReelSeconds { throw Problem.tooLong(name, Int(maxReelSeconds)) }
            return CreateSource(url: url, isVideo: true, width: Int(abs(upright.width).rounded()), height: Int(abs(upright.height).rounded()),
                                durationMs: Int(seconds * 1000))
        }
        guard type.conforms(to: .image), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Problem.unsupported(name) }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        return CreateSource(url: url, isVideo: false, width: swapped ? h : w, height: swapped ? w : h)
    }

    /// A still of the source no larger than `maxPixels` on its long side, upright.
    @concurrent
    static func still(_ source: CreateSource, maxPixels: Int) async -> CGImage? {
        if source.isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? await gen.image(at: CMTime(value: 1, timescale: 100)).image
        }
        guard let src = CGImageSourceCreateWithURL(source.url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: Cropping

    /// The part of the source (0…1 on each axis) a crop of `ratio` keeps, centred on `center`
    /// (also 0…1) and pushed back inside the picture.
    static func cropRect(sourceAspect: CGFloat, ratio: CGFloat, center: CGPoint) -> CGRect {
        var w: CGFloat = 1, h: CGFloat = 1
        if sourceAspect > ratio { w = ratio / sourceAspect } else { h = sourceAspect / ratio }
        let x = min(max(center.x - w / 2, 0), 1 - w)
        let y = min(max(center.y - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Output size for a crop: at most 1080 wide, the exact shape, even sides for video.
    static func outputSize(cropPixels: CGSize, ratio: CGFloat, even: Bool) -> (Int, Int) {
        var w = min(CGFloat(maxWidth), cropPixels.width.rounded(.down))
        var h = (w / ratio).rounded()
        if h > cropPixels.height.rounded(.down), cropPixels.height > 0 {
            h = cropPixels.height.rounded(.down)
            w = min(w, (h * ratio).rounded())
        }
        var (iw, ih) = (max(Int(w), 2), max(Int(h), 2))
        if even { iw -= iw % 2; ih -= ih % 2 }
        return (iw, ih)
    }

    // MARK: Photos

    /// Crops and re-encodes a photo as a JPEG, decoding only as many pixels as the output needs.
    @concurrent
    static func renderPhoto(_ source: CreateSource, crop: CGRect, ratio: CGFloat) async throws -> PreparedMedia {
        let name = source.url.lastPathComponent
        let cropPx = CGSize(width: crop.width * CGFloat(source.width), height: crop.height * CGFloat(source.height))
        let (outW, outH) = outputSize(cropPixels: cropPx, ratio: ratio, even: false)
        // Decode at the scale where the crop is about as wide as the output.
        let scale = min(1, CGFloat(outW) / max(cropPx.width, 1))
        let maxSide = Int((CGFloat(max(source.width, source.height)) * scale).rounded(.up)) + 2
        guard let image = await still(source, maxPixels: maxSide) else { throw Problem.unreadable(name) }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Problem.unreadable(name) }
        ctx.interpolationQuality = .high
        // Draw the whole image so the crop fills the context (Core Graphics is bottom-up).
        let sx = CGFloat(outW) / (crop.width * iw), sy = CGFloat(outH) / (crop.height * ih)
        let drawRect = CGRect(x: -crop.minX * iw * sx, y: -(1 - crop.maxY) * ih * sy, width: iw * sx, height: ih * sy)
        ctx.draw(image, in: drawRect)
        guard let out = ctx.makeImage() else { throw Problem.unreadable(name) }
        let url = folder.appending(path: "photo-\(UUID().uuidString).jpg")
        try writeJPEG(out, to: url)
        return PreparedMedia(file: url, width: outW, height: outH)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Problem.unreadable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Problem.unreadable(url.lastPathComponent) }
    }

    // MARK: Videos

    /// Crops and re-encodes a video as H.264/AAC MP4 at most 1080 wide, and grabs its cover
    /// frame at `coverAt` seconds (0.01 s for a reel, as `DEFAULT_VIDEO_COVER_TIME`; 1 s for a
    /// story, as `polarisGetVideoCoverPhoto`).
    @concurrent
    static func renderVideo(_ source: CreateSource, crop: CGRect, ratio: CGFloat, coverAt: Double,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> PreparedMedia {
        let name = source.url.lastPathComponent
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.unreadable(name) }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let W = abs(upright.width), H = abs(upright.height)
        let cropPx = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H)
        let (outW, outH) = outputSize(cropPixels: cropPx.size, ratio: ratio, even: true)
        let scale = CGFloat(outW) / cropPx.width

        // Upright (the track's own transform, moved back to the origin), then the crop, then the scale.
        let toUpright = transform.concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
        let placed = toUpright
            .concatenating(CGAffineTransform(translationX: -cropPx.minX, y: -cropPx.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: CGFloat(outH) / cropPx.height))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placed, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)
        let rate = fps > 0 ? min(Double(fps), 60) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        composition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Problem.unreadable(name)
        }
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true
        let url = folder.appending(path: "video-\(UUID().uuidString).mp4")
        // Only read from here (its progress), while `export` runs below.
        nonisolated(unsafe) let watched = export
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await export.export(to: url, as: .mp4)

        let out = AVURLAsset(url: url)
        let seconds = try await out.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: out)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let at = CMTime(seconds: min(coverAt, max(0, seconds - 0.05)), preferredTimescale: 600)
        let frame = try await gen.image(at: at).image
        let coverURL = folder.appending(path: "cover-\(UUID().uuidString).jpg")
        try writeJPEG(frame, to: coverURL)
        return PreparedMedia(file: url, width: outW, height: outH, durationMs: Int(seconds * 1000), cover: coverURL)
    }
}
