import AVFoundation
import ImageIO
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

// MARK: - A photo story with a song

nonisolated extension StoryExport {
    /// A photo story with a post's song, as the phone app makes it: the flattened photo as a
    /// still video for the length of the poster's part of the song (60 s at most), with that
    /// part as its sound. The photo is also its cover.
    @concurrent
    static func photoWithMusic(_ source: CreateSource, doc: StoryDoc, gradient: Gradient, music: MusicTrack) async throws -> PreparedMedia {
        let photo = try await StoryExport.photo(source, doc: doc, gradient: gradient)
        let seconds = min(Double(max(music.durationMs, 5000)) / 1000, CreateMedia.maxStorySeconds)
        guard let image = NSImageCGImage(photo.file) else { throw CreateMedia.Problem.unreadable(source.url.lastPathComponent) }

        // 1. The still video: the same frame at the start and the end.
        let still = CreateMedia.folder.appending(path: "story-still-\(UUID().uuidString).mp4")
        let w = Int(StoryDoc.size.width), h = Int(StoryDoc.size.height)
        let writer = try AVAssetWriter(outputURL: still, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoMaxKeyFrameIntervalKey: 30],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw CreateMedia.Problem.unreadable("story") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw CreateMedia.Problem.unreadable("story") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: StoryRenderer.sRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // A frame every second, so players and Instagram's transcoder see a steady video.
        var t = 0.0
        while t <= seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: min(t, seconds), preferredTimescale: 600))
            t += 1
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CreateMedia.Problem.unreadable("story") }

        // 2. The song's part as its sound.
        let (songTemp, _) = try await URLSession.shared.download(from: music.url)
        let song = CreateMedia.folder.appending(path: "story-song-\(UUID().uuidString).m4a")
        try FileManager.default.moveItem(at: songTemp, to: song)
        defer {
            try? FileManager.default.removeItem(at: song)
            try? FileManager.default.removeItem(at: still)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: still), songAsset = AVURLAsset(url: song)
        let length = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let vSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CreateMedia.Problem.unreadable("story") }
        try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: vSource, at: .zero)
        if let aSource = try await songAsset.loadTracks(withMediaType: .audio).first,
           let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let songLength = try await songAsset.load(.duration)
            let start = CMTime(value: CMTimeValue(music.startMs), timescale: 1000)
            let available = CMTimeSubtract(songLength, start)
            let take = CMTimeMinimum(length, available)
            if take > .zero { try aTrack.insertTimeRange(CMTimeRange(start: start, duration: take), of: aSource, at: .zero) }
        }
        let out = CreateMedia.folder.appending(path: "story-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CreateMedia.Problem.unreadable("story")
        }
        try await session.export(to: out, as: .mp4)
        return PreparedMedia(file: out, width: w, height: h, durationMs: Int(seconds * 1000), cover: photo.file)
    }

    private static func NSImageCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
