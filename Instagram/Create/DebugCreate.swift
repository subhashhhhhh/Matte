#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Debug-only test media (a solid-colour JPEG, a few seconds of coloured MP4 with a silent
/// sound track) and dry runs of every create flow, so the requests can be compared with the
/// recordings without touching anyone's files or account.
///
/// - `-IGMakeTestMedia <folder>`: writes `photo-a.jpg`, `photo-b.jpg`, `clip.mp4` and quits.
/// - `-IGCreateFiles 'a.jpg,b.jpg' [-IGCreateTarget post|reel|story] [-IGCreateShape square|portrait|landscape|tall]
///   [-IGCreateShare YES]`: opens the create sheet with those files (and presses Share).
/// - `-IGProbeCreate YES -IGDryRunWrites <folder> -IGProbeOut <file>`: runs each flow (post,
///   carousel, reel, story photo, story video, caption edit, delete, story delete, commenting)
///   with test media; the dry run records every request and sends nothing.
enum DebugCreate {
    static func makeTestMediaIfAsked() async {
        guard let dir = UserDefaults.standard.string(forKey: "IGMakeTestMedia") else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try makeJPEG(folder.appending(path: "photo-a.jpg"), width: 1600, height: 1200, color: (0.95, 0.55, 0.2))
            try makeJPEG(folder.appending(path: "photo-b.jpg"), width: 1080, height: 1350, color: (0.2, 0.5, 0.9))
            try await makeMP4(folder.appending(path: "clip.mp4"), seconds: 3, width: 720, height: 1280)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("test media: \(error)\n".utf8))
            exit(1)
        }
    }

    static func makeJPEG(_ url: URL, width: Int, height: Int, color: (Double, Double, Double)) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A lighter square in the middle, so crops can be seen.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.fill(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
        try CreateMedia.writeJPEG(ctx.makeImage()!, to: url)
    }

    /// Coloured frames that change hue each second, and silence for sound (so the AAC path runs).
    @concurrent
    static func makeMP4(_ url: URL, seconds: Int, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        writer.add(video)
        writer.add(audio)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        // Silence: 1024-frame packets of 16-bit mono PCM, kept in step with the frames (the
        // writer interleaves, so one input can't run far ahead of the other).
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let packet = 1024
        var written = 0
        let total = seconds * 44_100
        /// Appends silence up to `end` while the audio input takes it (never waits).
        func appendAudio(upTo end: Int) {
            while written < end, audio.isReadyForMoreMediaData, let format {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: packet * 2, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: packet * 2,
                                                   flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block else { return }
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet * 2)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                     sampleCount: packet, presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 44_100),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                if let sample { audio.append(sample) }
                written += packet
            }
        }
        for frame in 0..<(seconds * fps) {
            appendAudio(upTo: (frame + 1) * 44_100 / fps)
            // The writer interleaves: while video waits, feed it the sound it's waiting for.
            while !video.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CreateMedia.Problem.unreadable(url.lastPathComponent) }
                appendAudio(upTo: total)
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let hue = Double(frame / fps) / Double(seconds)
            let c = NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1)
            let rgb = c.usingColorSpace(.sRGB) ?? c
            var pixel: [UInt8] = [UInt8(rgb.blueComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.redComponent * 255), 255]
            memset_pattern4(CVPixelBufferGetBaseAddress(buffer)!, &pixel, CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        video.markAsFinished()
        while written < total {
            appendAudio(upTo: total)
            if written < total { try await Task.sleep(for: .milliseconds(2)) }
        }
        audio.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CreateMedia.Problem.unreadable(url.lastPathComponent) }
    }

    // MARK: Launch flags

    /// `-IGCreateFiles …`: opens the create sheet with test files (screenshots, dry runs).
    static func openIfAsked(_ app: AppModel) {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: "IGCreateFiles") else { return }
        let urls = raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        app.openCreate([])
        guard let model = app.creating else { return }
        Task {
            await model.add(urls)
            if let t = d.string(forKey: "IGCreateTarget").flatMap(CreateModel.Target.init(rawValue:)) {
                model.allowsStory = t == .story
                model.target = t
            }
            if let s = d.string(forKey: "IGCreateShape").flatMap(CropShape.init(rawValue:)), model.shapes.contains(s) { model.shape = s }
            if let c = d.string(forKey: "IGCreateCaption") { model.caption = c }
            // Only ever pressed for a dry run: a launch flag must never post for real.
            if d.bool(forKey: "IGCreateShare"), d.string(forKey: "IGDryRunWrites") != nil { model.share() }
        }
    }

    // MARK: Probe

    /// Runs every create flow through the dry run and reports how each ended.
    static func probe(_ client: IGClient) async throws -> JSON {
        let folder = FileManager.default.temporaryDirectory.appending(path: "probe-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appending(path: "a.jpg"), b = folder.appending(path: "b.jpg"), clip = folder.appending(path: "clip.mp4")
        try makeJPEG(a, width: 1600, height: 1200, color: (0.9, 0.5, 0.2))
        try makeJPEG(b, width: 1080, height: 1350, color: (0.2, 0.5, 0.9))
        try await makeMP4(clip, seconds: 3, width: 720, height: 1280)

        var results: [String: JSON] = [:]
        func flow(_ label: String, _ files: [URL], _ target: CreateModel.Target, caption: String = "test caption",
                  hide: Bool = false, commentsOff: Bool = false) async {
            let model = CreateModel(app: nil, client: client)
            model.allowsStory = target == .story
            await model.add(files)
            model.target = target
            model.caption = caption
            model.hideCounts = hide
            model.commentsOff = commentsOff
            await model.shareAndWait()
            results[label] = switch model.phase {
            case .failed(let m): .string(m)
            case .sharing: "still sharing?!"
            case .editing: "finished (sent?!)"
            }
        }
        await flow("post", [a], .post, hide: true, commentsOff: true)
        await flow("carousel", [a, b], .post)
        await flow("reel", [clip], .reel)
        await flow("story photo", [a], .story)
        await flow("story video", [clip], .story)

        var post = Media(id: "1000000000000000001_2000000001", pk: "1000000000000000001", kind: .image)
        post.user = User(id: "2000000001", username: "me", fullName: "")
        let calls: [(String, () async throws -> Void)] = [
            ("edit caption", { try await client.editCaption("edited caption", media: post) }),
            ("delete post", { try await client.deletePost(pk: post.pk) }),
            ("delete story", { try await client.deleteStory(pk: "1000000000000000002") }),
            ("comments on", { try await client.setCommentsEnabled(true, pk: post.pk) }),
            ("comments off", { try await client.setCommentsEnabled(false, pk: post.pk) }),
        ]
        for (label, call) in calls {
            do { try await call(); results[label] = "sent?!" } catch { results[label] = .string(error.localizedDescription) }
        }
        return .object(results)
    }
}
#endif
