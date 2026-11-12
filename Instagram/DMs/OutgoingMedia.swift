import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A photo or video waiting in the composer (picked, dropped or pasted), prepared for upload.
nonisolated struct StagedMedia: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// The file that gets uploaded.
    var file: URL
    var mimeType: String
    var isVideo: Bool
    /// A small still for the tray and the pending message (the photo itself, or a video frame).
    var preview: URL?
    var width: Int
    var height: Int
    var durationMs: Int?

    var attachment: DMAttachment {
        DMAttachment(kind: isVideo ? .video : (mimeType == "image/gif" ? .gif : .image), id: nil,
                     url: isVideo ? file : preview ?? file, preview: preview ?? file, width: width, height: height, durationMs: durationMs)
    }
}

/// Turns files and pasted images into `StagedMedia`: photos are re-encoded as JPEG at most
/// 2048 px (GIFs kept), videos kept as they are with a still for the preview. Instagram takes
/// attachments up to 25 MB from the web.
nonisolated enum OutgoingMedia {
    static let maxBytes = 25 << 20

    enum Problem: LocalizedError {
        case unsupported(String), tooLarge(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let n): "\(n) isn't a photo or video."
            case .tooLarge(let n): "\(n) is larger than Instagram's 25 MB limit."
            }
        }
    }

    /// A folder for prepared uploads; emptied at launch.
    static let folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Outgoing", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func prepare(file url: URL) async throws -> StagedMedia {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        let name = url.lastPathComponent
        guard let type else { throw Problem.unsupported(name) }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else { throw Problem.tooLarge(name) }
            return try await video(url, mime: type.preferredMIMEType ?? "video/mp4")
        }
        guard type.conforms(to: .image), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Problem.unsupported(name) }
        return try image(data, name: name, isGIF: type.conforms(to: .gif))
    }

    /// A pasted image (any format NSImage reads).
    static func prepare(imageData data: Data) throws -> StagedMedia {
        try image(data, name: "Pasted image", isGIF: false)
    }

    private static func image(_ data: Data, name: String, isGIF: Bool) throws -> StagedMedia {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw Problem.unsupported(name) }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        if isGIF {
            guard data.count <= maxBytes else { throw Problem.tooLarge(name) }
            let out = folder.appending(path: "\(UUID().uuidString).gif")
            try data.write(to: out)
            return StagedMedia(file: out, mimeType: "image/gif", isVideo: false, preview: out, width: w, height: h)
        }
        // Re-encode: upright, at most 2048 px, JPEG (what Instagram stores anyway).
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 2048]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { throw Problem.unsupported(name) }
        let out = folder.appending(path: "\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Problem.unsupported(name) }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Problem.unsupported(name) }
        return StagedMedia(file: out, mimeType: "image/jpeg", isVideo: false, preview: out, width: cg.width, height: cg.height)
    }

    private static func video(_ url: URL, mime: String) async throws -> StagedMedia {
        let asset = AVURLAsset(url: url)
        var w = 0, h = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            w = Int(abs(r.width)); h = Int(abs(r.height))
        }
        let duration = (try? await asset.load(.duration)).map { Int($0.seconds * 1000) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        var preview: URL?
        if let (cg, _) = try? await generator.image(at: .zero) {
            let out = folder.appending(path: "\(UUID().uuidString).jpg")
            if let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                if CGImageDestinationFinalize(dest) { preview = out }
            }
        }
        return StagedMedia(file: url, mimeType: mime, isVideo: true, preview: preview, width: w, height: h, durationMs: duration)
    }

    /// Photos or videos on a pasteboard (copied files, or image data).
    @MainActor static func pasteboardHasMedia(_ pb: NSPasteboard = .general) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: isMediaFile) { return true }
        // Text copied from a web page can carry an image too; plain text wins then.
        if pb.string(forType: .string) != nil { return false }
        return pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil
    }

    static func isMediaFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }
}
