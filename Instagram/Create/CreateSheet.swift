import SwiftUI
import UniformTypeIdentifiers

/// instagram.com's create dialog, desktop-sized: the picture with its crop on the left (drag
/// to place it, crops below, the carousel strip under that), caption and settings on the
/// right, Share at the top, and progress or the error along the bottom.
struct CreateSheet: View {
    let model: CreateModel
    @Environment(AppModel.self) private var app
    @FocusState private var captionFocused: Bool

    var body: some View {
        DialogCard(width: 1000, height: 640, close: close) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if model.items.isEmpty {
                    DropZone(loading: model.loading, notice: model.notice, pick: pick) { urls in
                        Task { await model.add(urls) }
                    }
                } else {
                    HStack(spacing: 0) {
                        editor
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        details.frame(width: 340)
                    }
                    .allowsHitTesting(!model.isSharing)
                }
                footer
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await model.add(await Self.urls(from: providers)) }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            Spacer()
            Text(title).font(.system(size: 15, weight: .bold))
            Spacer()
            Button(model.isScheduling ? "Schedule" : "Share") { app.shareInBackground() }
                .buttonStyle(.prominentCompact)
                .disabled(!model.canShare)
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(model.items.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var title: String {
        if model.items.isEmpty { return model.target == .reel ? "Create new reel" : "Create new post" }
        return switch model.target {
        case .post: model.items.count > 1 ? "New carousel" : "New post"
        case .reel: "New reel"
        case .story: "New story"
        }
    }

    // MARK: Editor (left)

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.primary.opacity(0.035)
                if let item = model.selected {
                    CropCanvas(model: model, item: item)
                        .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            HStack(spacing: 6) {
                ForEach(model.shapes) { shape in
                    CropChip(shape: shape, selected: model.shape == shape) {
                        withAnimation(Motion.slide) { model.shape = shape }
                    }
                }
                Spacer()
                if let notice = model.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            FilmStrip(model: model, canAdd: model.target == .post && !model.isVideo) { pick() }
        }
    }

    // MARK: Details (right)

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let me = app.me {
                    HStack(spacing: 10) {
                        Avatar(url: me.avatar, size: 30)
                        Text(me.username).font(.system(size: 14, weight: .semibold))
                    }
                }
                if model.target != .story {
                    VStack(alignment: .trailing, spacing: 6) {
                        CaptionField(text: Binding(get: { model.caption }, set: { model.caption = $0 }),
                                     focused: $captionFocused, height: 170)
                        CaptionCounter(count: model.caption.count)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if model.targets.count > 1 {
                        Text("Share as").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        SegmentedTabs(tabs: model.targets.map { ($0, $0.title) },
                                      selection: Binding(get: { model.target }, set: { model.target = $0 }))
                    }
                    Text(targetNote).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.target != .story {
                    VStack(spacing: 0) {
                        SettingRow(title: "Hide like and view counts",
                                   detail: "Only you will see the total number of likes and views.",
                                   isOn: Binding(get: { model.hideCounts }, set: { model.hideCounts = $0 }))
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10)
                        SettingRow(title: "Turn off commenting",
                                   detail: "You can change this later from the ⋯ menu on your post.",
                                   isOn: Binding(get: { model.commentsOff }, set: { model.commentsOff = $0 }))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
                }
                // Manager mode: Instagram publishes it later.
                if model.canSchedule {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingRow(title: "Schedule",
                                   detail: "Instagram publishes it at the time you pick, even when your Mac is off. Needs a professional account.",
                                   isOn: Binding(get: { model.scheduleAt != nil },
                                                 set: { model.scheduleAt = $0 ? SchedulePicker.clamp(.now.addingTimeInterval(3600)) : nil }))
                        if let at = model.scheduleAt {
                            SchedulePicker(date: Binding(get: { at }, set: { model.scheduleAt = $0 }))
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
                    .animation(.easeOut(duration: 0.16), value: model.scheduleAt == nil)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }

    private var targetNote: String {
        switch model.target {
        case .post: model.items.count > 1 ? "A carousel of \(model.items.count) photos on your profile." : "A photo on your profile and in your followers' feeds."
        case .reel: "A reel on your profile and in Reels."
        case .story: "Shown to your followers for 24 hours."
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .sharing:
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 14) {
                    Spinner(size: 14)
                    Text(model.status).font(.system(size: 13, weight: .medium))
                    ProgressTrack(value: model.progress)
                    Text("\(Int(model.progress * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Button("Cancel") { model.cancel() }.buttonStyle(.secondaryPill)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .failed(let message):
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.like)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't share").font(.system(size: 13, weight: .semibold))
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Try Again") { model.share() }.buttonStyle(.prominentCompact)
                }
                .padding(.horizontal, 16)
                .frame(height: 58)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Files

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        let reel = model.items.isEmpty && model.target == .reel
        panel.allowsMultipleSelection = !reel
        panel.allowedContentTypes = reel ? [.movie] : [.image, .movie]
        panel.message = reel ? "Choose a video" : "Choose photos or a video"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.add(urls) }
    }

    nonisolated static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let u = URL(dataRepresentation: url, relativeTo: nil) {
                out.append(u)
            }
        }
        return out
    }

    private func close() {
        if model.isSharing { model.cancel() }
        app.closeCreate()
    }
}

// MARK: - Pieces

/// The empty sheet: drop files here or pick them.
private struct DropZone: View {
    let loading: Bool
    let notice: String?
    let pick: () -> Void
    let drop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            IGGlyph(icon: .media, size: 72).foregroundStyle(.primary.opacity(targeted ? 1 : 0.8))
            Text("Drag photos and videos here").font(.system(size: 19, weight: .regular))
            if let notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            if loading {
                Spinner(size: 18)
            } else {
                Button("Select from computer", action: pick)
                    .buttonStyle(ProminentButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.primary.opacity(targeted ? 0.35 : 0))
            .padding(16))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { drop(await CreateSheet.urls(from: providers)) }
            return true
        }
    }
}

/// The picture behind a crop frame of the chosen shape. Dragging moves the picture under the
/// frame; outside it the picture shows dimmed, with thirds lines while you drag.
private struct CropCanvas: View {
    let model: CreateModel
    let item: CreateModel.Item
    @State private var start: CGPoint?

    var body: some View {
        GeometryReader { g in
            let r = model.ratio
            let fw = min(g.size.width, g.size.height * r), fh = fw / r
            let crop = model.cropRect(for: item)
            let iw = fw / crop.width, ih = fh / crop.height
            let fx = (g.size.width - fw) / 2, fy = (g.size.height - fh) / 2
            let ix = fx - crop.minX * iw, iy = fy - crop.minY * ih
            ZStack(alignment: .topLeading) {
                picture.frame(width: iw, height: ih).offset(x: ix, y: iy).opacity(0.28)
                picture.frame(width: iw, height: ih).offset(x: ix - fx, y: iy - fy)
                    .frame(width: fw, height: fh, alignment: .topLeading).clipped()
                    .offset(x: fx, y: fy)
                thirds.frame(width: fw, height: fh).offset(x: fx, y: fy).opacity(start == nil ? 0 : 1)
                RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: fw, height: fh).offset(x: fx, y: fy)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                if item.source.isVideo, let ms = item.source.durationMs {
                    Label(Self.duration(ms), systemImage: "video.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .offset(x: fx + 10, y: fy + 10)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let from = start ?? item.center
                    if start == nil { start = from }
                    model.setCenter(CGPoint(x: from.x - v.translation.width / iw, y: from.y - v.translation.height / ih), for: item.id)
                }
                .onEnded { _ in start = nil })
            .animation(Motion.slide, value: r)
            .pointerStyle(start == nil ? .grabIdle : .grabActive)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = model.canvasImage {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
        } else if let thumb = item.thumb {
            Image(decorative: thumb, scale: 1).resizable()
        } else {
            Color.primary.opacity(0.1)
        }
    }

    private var thirds: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.5)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One crop choice, with Instagram's crop glyph.
private struct CropChip: View {
    let shape: CropShape
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    switch shape {
                    case .original: Image(systemName: "photo").font(.system(size: 12))
                    case .square: IGGlyph(icon: .cropSquare, size: 14)
                    case .portrait: IGGlyph(icon: .cropPortrait, size: 14)
                    case .landscape: IGGlyph(icon: .cropLandscape, size: 14)
                    case .tall: IGGlyph(icon: .cropPortrait, size: 14).scaleEffect(x: 0.8, y: 1)
                    }
                }
                .frame(width: 16, height: 16)
                Text(shape.title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(.primary.opacity(selected ? 0.12 : hovering ? 0.07 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}

/// The picked items in order: click to edit one, drag to reorder, × to remove, + to add.
private struct FilmStrip: View {
    let model: CreateModel
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                    Thumb(item: item, index: i, count: model.items.count, selected: model.selected?.id == item.id, model: model)
                }
                if canAdd, model.items.count < CreateMedia.maxItems {
                    Button(action: add) {
                        IGGlyph(icon: .newPost, size: 22)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.panelStroke, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .help("Add photos")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(height: 84)
    }

    private struct Thumb: View {
        let item: CreateModel.Item
        let index: Int
        let count: Int
        let selected: Bool
        let model: CreateModel
        @State private var hovering = false

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = item.thumb {
                        Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.1)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                .overlay(alignment: .bottomLeading) {
                    if count > 1 {
                        Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(Circle().fill(.black.opacity(0.55))).padding(4)
                    }
                }
                if hovering {
                    Button { model.remove(item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Circle().fill(.black.opacity(0.7)))
                    }
                    .buttonStyle(.pressable)
                    .padding(3)
                    .help("Remove")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(item.id) }
            .onHover { hovering = $0 }
            .draggable(item.id.uuidString)
            .dropDestination(for: String.self) { ids, _ in
                guard let raw = ids.first, let id = UUID(uuidString: raw) else { return false }
                withAnimation(Motion.slide) { model.move(id, before: item.id) }
                return true
            }
            .contextMenu {
                if index > 0 { Button("Move Left") { withAnimation(Motion.slide) { model.move(item.id, by: -1) } } }
                if index < count - 1 { Button("Move Right") { withAnimation(Motion.slide) { model.move(item.id, by: 1) } } }
                Button("Remove") { model.remove(item.id) }
            }
        }
    }
}

/// A setting with a line of explanation and a switch.
private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            PillSwitch(isOn: $isOn)
        }
    }
}

/// A thin bar that fills smoothly.
struct ProgressTrack: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(Theme.link).frame(width: max(6, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}
