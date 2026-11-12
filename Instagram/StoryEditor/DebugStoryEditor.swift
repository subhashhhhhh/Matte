#if DEBUG
import AppKit
import AVFoundation

/// Debug-only: opens the story editor on generated test media (never the user's files), adds
/// sample content for screenshots, and exports or dry-runs a share.
///
/// - `-IGStoryEditor photo|landscape|video|rotated|empty`: opens the editor with a generated
///   portrait photo, a landscape photo (gradient fill), an 8 s video with sound, or a video
///   recorded sideways (a rotation in its track transform).
/// - `-IGStorySample YES`: adds two texts (one neon), a sticker and a drawing.
/// - `-IGStoryMode text|draw|stickers|filters`, `-IGStoryFilter oslo`, `-IGStorySelect YES`,
///   `-IGStoryTrim 'start,end'`, `-IGStoryMute YES`, `-IGStoryZoom 1.4`: the state to show.
/// - `-IGStoryExport <dir>`: renders the story to `<dir>` (`story.jpg` or `story.mp4` and
///   `cover.jpg`, plus `export.json` with sizes) and quits. Nothing is shared.
/// - `-IGStoryKeep <dir>`: a copy of every file the editor makes before sharing.
/// - `-IGStoryShare YES` with `-IGDryRunWrites <dir>`: presses Share (dry run only).
@MainActor
enum DebugStoryEditor {
    static func openIfAsked(_ app: AppModel) {
        let d = UserDefaults.standard
        // `-IGShowCreateMenu YES`: the "+" menu. `-IGDropTest video|photo`: as if a generated
        // test file were dropped on the window.
        if d.bool(forKey: "IGShowCreateMenu") { app.showCreateMenu = true }
        if let kind = d.string(forKey: "IGDropTest") {
            Task { if let url = try? await makeMedia(kind) { app.dropped([url]) } }
        }
        guard let kind = d.string(forKey: "IGStoryEditor") else { return }
        app.openStoryEditor()
        guard let model = app.storyEditor else { return }
        Task {
            if kind != "empty" {
                do {
                    let url = try await makeMedia(kind)
                    await model.load(url)
                } catch {
                    FileHandle.standardError.write(Data("story test media: \(error)\n".utf8))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            if d.bool(forKey: "IGStorySelfTest") { await selfTest(model) }
            apply(model)
            if let dir = d.string(forKey: "IGStoryExport") { await exportAndQuit(model, to: URL(fileURLWithPath: dir)) }
            if d.bool(forKey: "IGStoryShare"), d.string(forKey: "IGDryRunWrites") != nil { model.share() }
        }
    }

    /// The flags that set up what the editor shows.
    static func apply(_ model: StoryEditorModel) {
        let d = UserDefaults.standard
        if d.bool(forKey: "IGStorySample") { addSample(model) }
        if let f = d.string(forKey: "IGStoryFilter").flatMap(StoryFilter.init(rawValue:)) { model.setFilter(f) }
        if let raw = d.string(forKey: "IGStoryTrim") {
            let p = raw.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 { model.debugSet { $0.trimStart = p[0]; $0.trimEnd = p[1] } }
        }
        if d.bool(forKey: "IGStoryMute") { model.debugSet { $0.muted = true } }
        let zoom = d.double(forKey: "IGStoryZoom")
        if zoom > 0 { model.debugSet { $0.bgScale = zoom } }
        if d.bool(forKey: "IGStorySelect") { model.selection = model.doc.items.last?.id }
        switch d.string(forKey: "IGStoryMode") {
        case "text":
            if let t = model.doc.items.first(where: { $0.text != nil }) { model.editText(t.id) } else { model.addText() }
        case "draw": model.setMode(.draw)
        case "stickers": model.setMode(.stickers)
        case "filters": model.setMode(.filters)
        default: break
        }
        // `-IGStoryClose YES`: presses Close (asks first when there are edits).
        if d.bool(forKey: "IGStoryClose") { model.requestClose() }
    }

    static func addSample(_ model: StoryEditorModel) {
        model.debugSet { d in
            var title = StoryItem(kind: .text(StoryText(string: "Golden hour", style: .strong, color: .white, highlight: .none)))
            title.center = CGPoint(x: 540, y: 420)
            title.rotation = -0.08
            title.scale = 1.2
            var note = StoryItem(kind: .text(StoryText(string: "made in Matte\non a Mac", style: .classic,
                                                       color: StoryColor(hex: 0xFD8D32), highlight: .solid)))
            note.center = CGPoint(x: 360, y: 1380)
            var neon = StoryItem(kind: .text(StoryText(string: "neon nights", style: .neon, color: StoryColor(hex: 0xD10869))))
            neon.center = CGPoint(x: 600, y: 1640)
            neon.rotation = 0.12
            var sticker = StoryItem(kind: .sticker("🔥"))
            sticker.center = CGPoint(x: 840, y: 1120)
            sticker.scale = 1.3
            sticker.rotation = 0.2
            d.items = [title, note, neon, sticker]
            var squiggle: [CGPoint] = []
            for i in 0...60 {
                let t = Double(i) / 60
                squiggle.append(CGPoint(x: 140 + 800 * t, y: 760 + 70 * sin(t * .pi * 4)))
            }
            let loop = (0...40).map { i -> CGPoint in
                let a = Double(i) / 40 * 2 * .pi
                return CGPoint(x: 260 + 90 * cos(a), y: 1080 + 90 * sin(a))
            }
            d.strokes = [StoryStroke(brush: .neon, color: StoryColor(hex: 0x3897F0), width: StoryStroke.widths[1], points: squiggle),
                         StoryStroke(brush: .marker, color: StoryColor(hex: 0xFDCB5C), width: StoryStroke.widths[1], points: loop),
                         StoryStroke(brush: .eraser, color: .white, width: StoryStroke.widths[0],
                                     points: [CGPoint(x: 520, y: 700), CGPoint(x: 540, y: 840)])]
        }
    }

    /// `-IGStorySelfTest YES`: runs the editor's edits and undo through the model, prints
    /// PASS/FAIL lines and quits (exit 0 when all pass).
    static func selfTest(_ m: StoryEditorModel) async {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        check("starts blank", m.hasMedia && m.doc.isBlank && !m.canUndo && !m.hasEdits)
        m.addText()
        m.draft.string = "Hi"
        m.finishText()
        let first = m.doc.items.first?.id
        check("text added as one step", m.doc.items.count == 1 && m.canUndo && m.selection == first)
        m.undo()
        check("undo removes it", m.doc.items.isEmpty && m.canRedo)
        m.redo()
        check("redo brings it back", m.doc.items.first?.text?.string == "Hi")
        m.addText()
        m.draft.string = "   "
        m.finishText()
        check("empty text is dropped", m.doc.items.count == 1)
        m.undo()
        check("…and left no undo step", m.doc.items.isEmpty)
        m.redo()
        if let id = m.doc.items.first?.id {
            m.editText(id)
            m.draft.string = "Hello"
            m.draft.style = .neon
            m.finishText()
            check("edit applies", m.doc.items.first?.text?.string == "Hello" && m.doc.items.first?.text?.style == .neon)
            m.undo()
            check("undo the edit", m.doc.items.first?.text?.string == "Hi")
        }
        m.addSticker("🔥")
        let sticker = m.selection
        check("sticker added and selected", m.doc.items.count == 2 && sticker == m.doc.items.last?.id)
        if let sticker {
            let before = m.doc.items.last?.center
            m.nudge(sticker, by: CGSize(width: 20, height: -2))
            check("nudge moves it", m.doc.items.last?.center.x == (before?.x ?? 0) + 20)
            m.delete(sticker)
            check("delete removes it", m.doc.items.count == 1 && m.selection == nil)
            m.undo()
            check("undo delete", m.doc.items.count == 2)
        }
        m.setMode(.draw)
        m.brush = .neon
        m.addStroke([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)])
        check("stroke drawn", m.doc.strokes.count == 1 && m.drawingImage != nil)
        m.undo()
        check("undo stroke clears the drawing", m.doc.strokes.isEmpty && m.drawingImage == nil)
        m.redo()
        m.setMode(.normal)
        m.setFilter(.oslo)
        try? await Task.sleep(for: .milliseconds(500))
        check("filter previewed", m.doc.filter == .oslo && m.filtered != nil)
        m.stepFilter(1)
        check("arrow steps the filter", m.doc.filter == .lagos)
        m.undoAll()
        check("undo all", !m.hasEdits && m.doc.isBlank && m.doc.filter == .normal)
        m.undo()
        check("undo all can be undone", m.doc.items.count == 2 && m.doc.strokes.count == 1)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Keeps a copy of what's about to be shared (`-IGStoryKeep <dir>`).
    nonisolated static func keep(_ media: PreparedMedia) {
        guard let dir = UserDefaults.standard.string(forKey: "IGStoryKeep") else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [media.file] + (media.cover.map { [$0] } ?? []) {
            let to = folder.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: url, to: to)
        }
    }

    private static func exportAndQuit(_ model: StoryEditorModel, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let started = Date.now
        do {
            guard let media = try await model.exportOnly() else { throw CreateMedia.Problem.unreadable("story") }
            let ext = media.file.pathExtension
            let out = dir.appending(path: "story." + ext)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.copyItem(at: media.file, to: out)
            var info: [String: JSON] = ["file": .string(out.lastPathComponent), "width": .integer(Int64(media.width)),
                                        "height": .integer(Int64(media.height)),
                                        "bytes": .integer(Int64((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)),
                                        "seconds": .number(Date.now.timeIntervalSince(started))]
            if let ms = media.durationMs { info["durationMs"] = .integer(Int64(ms)) }
            if let cover = media.cover {
                let c = dir.appending(path: "cover.jpg")
                try? FileManager.default.removeItem(at: c)
                try FileManager.default.copyItem(at: cover, to: c)
            }
            if ext == "mp4" {
                let asset = AVURLAsset(url: out)
                var tracks: [JSON] = []
                for t in (try? await asset.load(.tracks)) ?? [] {
                    let formats = (try? await t.load(.formatDescriptions)) ?? []
                    let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }.map(fourCC) ?? "?"
                    var entry: [String: JSON] = ["type": .string(t.mediaType.rawValue), "codec": .string(codec)]
                    if t.mediaType == .video, let size = try? await t.load(.naturalSize) {
                        entry["size"] = .string("\(Int(size.width))x\(Int(size.height))")
                    }
                    tracks.append(.object(entry))
                }
                info["tracks"] = .array(tracks)
            }
            try JSON.object(info).data().write(to: dir.appending(path: "export.json"))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("story export: \(error)\n".utf8))
            exit(1)
        }
    }

    nonisolated private static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Test media

    static var folder: URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "StoryTestMedia", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeMedia(_ kind: String) async throws -> URL {
        switch kind {
        case "landscape":
            let url = folder.appending(path: "landscape.jpg")
            try makePhoto(url, width: 2400, height: 1600)
            return url
        case "video":
            let url = folder.appending(path: "clip.mp4")
            try await DebugCreate.makeMP4(url, seconds: 8, width: 720, height: 1280)
            return url
        case "rotated":
            let url = folder.appending(path: "rotated.mov")
            try await makeRotated(url)
            return url
        default:
            let url = folder.appending(path: "portrait.jpg")
            try makePhoto(url, width: 1500, height: 2000)
            return url
        }
    }

    /// A sunset of sorts: a sky gradient, a sun, hills and stripes, so filters show.
    nonisolated static func makePhoto(_ url: URL, width: Int, height: Int) throws {
        let w = CGFloat(width), h = CGFloat(height)
        guard let ctx = StoryRenderer.context(width: width, height: height) else { throw CreateMedia.Problem.unreadable("test") }
        let sky = CGGradient(colorsSpace: StoryRenderer.sRGB, colors: [
            CGColor(srgbRed: 0.16, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.93, green: 0.45, blue: 0.4, alpha: 1),
            CGColor(srgbRed: 0.99, green: 0.78, blue: 0.4, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [.drawsAfterEndLocation])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.38, width: w * 0.26, height: w * 0.26))
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.32, blue: 0.24, alpha: 1))
        ctx.addEllipse(in: CGRect(x: -w * 0.3, y: -h * 0.25, width: w * 1.1, height: h * 0.62))
        ctx.fillPath()
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.22, blue: 0.2, alpha: 1))
        ctx.addEllipse(in: CGRect(x: w * 0.3, y: -h * 0.3, width: w * 1.1, height: h * 0.6))
        ctx.fillPath()
        // Colour bars along the bottom: red, green, blue, white, grey, black.
        let bars: [(Double, Double, Double)] = [(0.9, 0.15, 0.15), (0.15, 0.75, 0.25), (0.15, 0.35, 0.9), (1, 1, 1), (0.5, 0.5, 0.5), (0, 0, 0)]
        let bw = w / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: 0, width: bw, height: h * 0.06))
        }
        try CreateMedia.writeJPEG(ctx.makeImage()!, to: url)
    }

    /// 5 s recorded sideways: 1280×720 frames with a 90° track transform (shows as portrait),
    /// a white bar on what is the top once upright, and a block moving down the picture.
    nonisolated static func makeRotated(_ url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let (w, h, fps, seconds) = (1280, 720, 30, 5)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        // Rotated 90° clockwise for display, as an iPhone records portrait video.
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: StoryRenderer.sRGB,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.55, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                // Stored frame's left edge = the top once turned 90° clockwise.
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 90, height: h))
                ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1))
                let x = 120 + CGFloat(frame) / CGFloat(fps * seconds) * CGFloat(w - 360)
                ctx.fill(CGRect(x: x, y: CGFloat(h) / 2 - 100, width: 200, height: 200))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CreateMedia.Problem.unreadable(url.lastPathComponent) }
    }
}
#endif
