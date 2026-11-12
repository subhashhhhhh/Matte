import AVFoundation
import CoreImage
import Foundation

/// Flattens an edited story into the files the story upload takes: a 1080×1920 JPEG, or a
/// 1080×1920 H.264/AAC MP4 with its cover frame. Instagram does no editing of its own, so
/// everything on the canvas is baked into the pixels here.
///
/// Video: an `AVMutableComposition` keeps the trimmed part (and the sound unless muted); a
/// Core Image video composition draws each frame with the same recipe as the photo export
/// (`StoryRenderer.compose`: gradient, placed and filtered picture, overlay on top). The
/// overlay is composited in that pass rather than by `AVVideoCompositionCoreAnimationTool`,
/// which AVFoundation ignores for Core Image compositions (tried: the layer never appears).
nonisolated enum StoryExport {
    typealias Gradient = (top: StoryColor, bottom: StoryColor)

    /// Shared: a Core Image context is expensive to make.
    private static let context = CIContext(options: [.workingColorSpace: StoryRenderer.sRGB, .cacheIntermediates: false])

    @concurrent
    static func photo(_ source: CreateSource, doc: StoryDoc, gradient: Gradient) async throws -> PreparedMedia {
        let name = source.url.lastPathComponent
        // Decode only as many pixels as the canvas shows of it (full size at most).
        let bg = doc.bgRect(aspect: source.aspect)
        let long = max(source.width, source.height)
        let needed = min(long, Int((CGFloat(long) * bg.width / CGFloat(max(source.width, 1))).rounded(.up)) + 2)
        guard let still = await CreateMedia.still(source, maxPixels: max(needed, 64)) else { throw CreateMedia.Problem.unreadable(name) }
        let overlay = StoryRenderer.overlay(doc).map { CIImage(cgImage: $0) }
        let frame = StoryRenderer.compose(source: CIImage(cgImage: still), doc: doc, gradient: gradient, overlay: overlay)
        guard let out = context.createCGImage(frame, from: CGRect(origin: .zero, size: StoryDoc.size), format: .RGBA8,
                                              colorSpace: StoryRenderer.sRGB) else { throw CreateMedia.Problem.unreadable(name) }
        let url = CreateMedia.folder.appending(path: "story-\(UUID().uuidString).jpg")
        try CreateMedia.writeJPEG(out, to: url)
        return PreparedMedia(file: url, width: Int(StoryDoc.size.width), height: Int(StoryDoc.size.height))
    }

    @concurrent
    static func video(_ source: CreateSource, doc: StoryDoc, gradient: Gradient,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> PreparedMedia {
        let name = source.url.lastPathComponent
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CreateMedia.Problem.unreadable(name) }
        let (transform, fps) = try await track.load(.preferredTransform, .nominalFrameRate)
        let length = try await asset.load(.duration).seconds
        let start = max(0, min(doc.trimStart, length)), end = min(length, max(doc.trimEnd, start + CreateMedia.minVideoSeconds))
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CreateMedia.Problem.unreadable(name)
        }
        try video.insertTimeRange(range, of: track, at: .zero)
        video.preferredTransform = transform
        if !doc.muted, let sound = try await asset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(range, of: sound, at: .zero)
        }

        // Made once; read (never changed) by each frame's render.
        nonisolated(unsafe) let overlay = StoryRenderer.overlay(doc).map { CIImage(cgImage: $0) }
        let frames = try await AVVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { request in
            let image = StoryRenderer.compose(source: request.sourceImage, doc: doc, gradient: gradient, overlay: overlay)
            request.finish(with: image, context: nil)
        })
        guard let shaped = frames.mutableCopy() as? AVMutableVideoComposition else { throw CreateMedia.Problem.unreadable(name) }
        shaped.renderSize = StoryDoc.size
        let rate = fps > 0 ? min(Double(fps), 60) : 30
        shaped.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CreateMedia.Problem.unreadable(name)
        }
        export.videoComposition = shaped
        export.shouldOptimizeForNetworkUse = true
        let url = CreateMedia.folder.appending(path: "story-\(UUID().uuidString).mp4")
        nonisolated(unsafe) let watched = export
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await export.export(to: url, as: .mp4)

        // The cover: the frame at 1 s, as `polarisGetVideoCoverPhoto` takes it.
        let out = AVURLAsset(url: url)
        let seconds = try await out.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: out)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cover = try await gen.image(at: CMTime(seconds: min(1, max(0, seconds - 0.05)), preferredTimescale: 600)).image
        let coverURL = CreateMedia.folder.appending(path: "story-cover-\(UUID().uuidString).jpg")
        try CreateMedia.writeJPEG(cover, to: coverURL)
        return PreparedMedia(file: url, width: Int(StoryDoc.size.width), height: Int(StoryDoc.size.height),
                             durationMs: Int(seconds * 1000), cover: coverURL)
    }
}
