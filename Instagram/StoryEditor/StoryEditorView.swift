import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The story editor, full window and dark, after Instagram's phone editor: the 9:16 canvas in
/// the middle, close and undo on the left, the tools (Aa, stickers, draw, filters, sound) on
/// the right, the current tool's options under the canvas, and "Your story" to share.
///
/// Keys: Esc steps back (typing → tool → selection → close), ⌘Z / ⇧⌘Z undo and redo,
/// Delete removes the selected piece, arrows nudge it (or change the filter), ⌘↩ shares.
/// Scroll or pinch zooms the selected piece, or the picture when nothing is selected.
struct StoryEditorView: View {
    let model: StoryEditorModel
    @Environment(AppModel.self) private var app
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var scrollEnd: Task<Void, Never>?
    @State private var canvasFrame: CGRect = .zero
    @State private var targeted = false

    private static let bottomHeight: CGFloat = 132

    var body: some View {
        ZStack {
            Color(white: 0.035).ignoresSafeArea()
            if model.hasMedia {
                editor
            } else {
                EmptyStoryPicker(model: model, close: { model.close() })
            }
            if model.mode == .stickers {
                StickerPicker(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }
            if model.confirmingClose {
                ConfirmDialog(title: "Discard this story?", message: "Your edits will be lost.", action: "Discard",
                              confirm: { model.confirmingClose = false; model.close() },
                              cancel: { model.confirmingClose = false })
                    .zIndex(10)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(Motion.pop, value: model.mode)
        .animation(.easeOut(duration: 0.14), value: model.confirmingClose)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !model.isBusy else { return false }
            Task {
                if let url = await CreateSheet.urls(from: providers).first(where: CreateMedia.isMedia) { await model.load(url) }
            }
            return true
        }
        .onAppear(perform: installMonitors)
        .onDisappear(perform: removeMonitors)
    }

    // MARK: Layout

    private var editor: some View {
        GeometryReader { g in
            let maxH = g.size.height - 64 - Self.bottomHeight
            let maxW = g.size.width - 2 * 150
            let h = max(320, min(maxH, maxW * 16 / 9)), w = h * 9 / 16
            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: 28) {
                    LeftColumn(model: model).frame(width: 110, alignment: .trailing)
                    VStack(spacing: 14) {
                        StoryCanvas(model: model, size: CGSize(width: w, height: h))
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { canvasFrame = $0 }
                            .overlay(alignment: .top) { CanvasTopBar(model: model).padding(12) }
                            .overlay(alignment: .leading) {
                                if model.mode == .draw { BrushSizes(model: model).padding(.leading, 10) }
                            }
                        BottomPanel(model: model, width: max(w, 440))
                            .frame(height: Self.bottomHeight - 14, alignment: .top)
                    }
                    RightColumn(model: model).frame(width: 110, alignment: .leading)
                }
                .padding(.top, 52)
                .frame(maxWidth: .infinity)
                ShareCorner(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(22)
            }
        }
    }

    // MARK: Keys and scrolling

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handleKey(e) ? nil : e
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            handleScroll(e) ? nil : e
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }

    /// True when the editor used the key.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard app.storyEditor === model else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if model.confirmingClose { return false }
        if e.keyCode == 53 { model.requestClose(); return true }  // Esc
        if model.editingText != nil { return false }  // the text field has the keys
        if mods.contains(.command) {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if mods.contains(.shift) { model.redo() } else { model.undo() }
                return true
            case "\r":
                model.share()
                return true
            default:
                return false
            }
        }
        guard model.hasMedia, !model.isBusy else { return false }
        let step: CGFloat = mods.contains(.shift) ? 20 : 2
        switch e.keyCode {
        case 51, 117:  // Delete, forward delete
            if let id = model.selection { withAnimation(Motion.pop) { model.delete(id) }; return true }
        case 123, 124:  // ← →
            if let id = model.selection { model.nudge(id, by: CGSize(width: e.keyCode == 123 ? -step : step, height: 0)); return true }
            if model.mode == .normal || model.mode == .filters { model.stepFilter(e.keyCode == 123 ? -1 : 1); return true }
        case 125, 126:  // ↓ ↑
            if let id = model.selection { model.nudge(id, by: CGSize(width: 0, height: e.keyCode == 126 ? -step : step)); return true }
        default:
            break
        }
        return false
    }

    /// Scrolling over the canvas zooms (the selected piece, or the picture).
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard app.storyEditor === model, model.hasMedia, !model.isBusy, model.editingText == nil,
              model.mode != .stickers, let window = e.window, let content = window.contentView else { return false }
        let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
        guard canvasFrame.contains(p) else { return false }
        let dy = e.scrollingDeltaY
        guard dy != 0 else { return true }
        let factor = exp(dy * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04))
        model.beginGesture()
        model.live { d in
            if let id = model.selection, let i = d.items.firstIndex(where: { $0.id == id }) {
                d.items[i].scale = min(8, max(0.2, d.items[i].scale * factor))
            } else {
                d.bgScale = min(6, max(0.3, d.bgScale * factor))
            }
        }
        // A burst of scrolling is one undo step.
        scrollEnd?.cancel()
        scrollEnd = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { model.endGesture() }
        }
        return true
    }
}

// MARK: - Side columns

private struct LeftColumn: View {
    let model: StoryEditorModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if model.editingText == nil, model.mode != .draw {
                RoundTool(symbol: "xmark", label: "Close", action: model.requestClose)
                    .help("Close (Esc)")
                RoundTool(symbol: "arrow.uturn.backward", label: "Undo", action: model.undo)
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                RoundTool(symbol: "arrow.uturn.forward", label: "Redo", action: model.redo)
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                if model.hasEdits {
                    Button("Undo all") { withAnimation(Motion.pop) { model.undoAll() } }
                        .buttonStyle(DarkPillStyle())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .disabled(model.isBusy)
        .animation(Motion.pop, value: model.hasEdits)
    }
}

private struct RightColumn: View {
    let model: StoryEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.editingText == nil, model.mode != .draw {
                RoundTool(text: "Aa", label: "Text", active: false) { model.addText() }
                    .help("Add text (or double-click the picture)")
                RoundTool(symbol: "face.smiling", label: "Stickers", active: model.mode == .stickers) { model.toggle(.stickers) }
                RoundTool(symbol: "scribble.variable", label: "Draw", active: false) { model.toggle(.draw) }
                RoundTool(symbol: "camera.filters", label: "Filters", active: model.mode == .filters) { model.toggle(.filters) }
                RoundTool(symbol: "circle.lefthalf.filled", label: "Background", active: model.mode == .background) { model.toggle(.background) }
                    .help("Filters (← → to change)")
                if model.isVideo {
                    RoundTool(symbol: model.doc.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              label: model.doc.muted ? "Sound off" : "Sound on", active: model.doc.muted) { model.toggleSound() }
                }
            }
        }
        .disabled(model.isBusy)
    }
}

/// A round dark tool button with a caption, Instagram's editor style.
private struct RoundTool: View {
    var symbol: String?
    var text: String?
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(active ? Color.white : .white.opacity(hovering ? 0.2 : 0.12))
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    } else if let text {
                        Text(text).font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(active ? .black : .white)
                .frame(width: 42, height: 42)
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Motion.slide, value: active)
    }
}

struct DarkPillStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(prominent ? Color.white : .white.opacity(configuration.isPressed ? 0.26 : 0.14)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Over the canvas

/// Along the canvas's top edge: the text tools while typing, the brushes while drawing.
private struct CanvasTopBar: View {
    let model: StoryEditorModel

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            if model.editingText != nil {
                CircleIcon(symbol: alignSymbol, help: "Alignment") { model.draft.alignment = model.draft.alignment.next }
                HighlightButton(highlight: model.draft.highlight) { model.draft.highlight = model.draft.highlight.next }
                Spacer()
                Button("Done") { model.finishText() }.buttonStyle(DarkPillStyle(prominent: true))
            } else if model.mode == .draw {
                ForEach(StoryStroke.Brush.allCases) { b in
                    CircleIcon(symbol: Self.symbol(b), help: b.title, active: model.brush == b) { model.brush = b }
                }
                Spacer()
                Button("Done") { model.setMode(.normal) }.buttonStyle(DarkPillStyle(prominent: true))
            }
        }
        .animation(Motion.slide, value: model.brush)
    }

    private var alignSymbol: String {
        switch model.draft.alignment {
        case .center: "text.aligncenter"
        case .left: "text.alignleft"
        case .right: "text.alignright"
        }
    }

    static func symbol(_ b: StoryStroke.Brush) -> String {
        switch b {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .neon: "wand.and.rays"
        case .eraser: "eraser"
        }
    }
}

private struct CircleIcon: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(active ? Color.white : .black.opacity(0.4)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .help(help)
    }
}

/// Instagram's "A" in a box: plain, filled, translucent.
private struct HighlightButton: View {
    let highlight: StoryHighlight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("A").font(.system(size: 15, weight: .heavy))
                .foregroundStyle(highlight == .solid ? .black : .white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlight == .solid ? Color.white : highlight == .translucent ? .white.opacity(0.4) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white, lineWidth: 1.5))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.4)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .help("Background: none, solid, translucent")
    }
}

/// The three brush sizes, down the canvas's left edge while drawing.
private struct BrushSizes: View {
    let model: StoryEditorModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(StoryStroke.widths.indices, id: \.self) { i in
                let selected = model.brushWidth == i
                Button { model.brushWidth = i } label: {
                    Circle().fill(.white)
                        .frame(width: 6 + CGFloat(i) * 5, height: 6 + CGFloat(i) * 5)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.black.opacity(selected ? 0.55 : 0.3)))
                        .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
            }
        }
        .help("Brush size")
        .animation(Motion.slide, value: model.brushWidth)
    }
}

// MARK: - Under the canvas

private struct BottomPanel: View {
    let model: StoryEditorModel
    let width: CGFloat

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 12) {
            if model.editingText != nil {
                StyleChips(style: $model.draft.style)
                Palette(color: $model.draft.color)
            } else if model.mode == .draw {
                Palette(color: $model.brushColor)
                Text(model.brush == .eraser ? "Drag to erase" : "Drag on the picture to draw")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else if model.mode == .filters {
                FilterStrip(model: model)
            } else if model.mode == .background {
                BackgroundStrip(model: model)
            } else {
                if let video = model.video {
                    TrimBar(model: model, video: video)
                }
                Text(hint).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: width)
        .disabled(model.isBusy)
        .transition(.opacity)
    }

    private var hint: String {
        if model.reshare != nil, model.selection == nil {
            return "Click the post to change its look · Drag or scroll to move it · Double-click to add text"
        }
        return model.selection != nil
            ? "Drag to move · Corner handle or pinch to resize and turn · Delete to remove"
            : "Double-click to add text · Drag or scroll to place the picture · ← → filters"
    }
}

private struct StyleChips: View {
    @Binding var style: StoryTextStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StoryTextStyle.allCases) { s in
                let selected = s == style
                Button { style = s } label: {
                    Text(s.title)
                        .font(Font(CTFontCreateCopyWithAttributes(StoryRenderer.font(s), 14, nil, nil)))
                        .foregroundStyle(selected ? .black : .white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(selected ? Color.white : .white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .animation(Motion.slide, value: style)
    }
}

/// Instagram's colour dots.
private struct Palette: View {
    @Binding var color: StoryColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StoryColor.palette, id: \.self) { c in
                let selected = c == color
                Button { color = c } label: {
                    Circle().fill(Color(cgColor: c.cg))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .scaleEffect(selected ? 1.25 : 1)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
            }
        }
        .animation(Motion.slide, value: color)
    }
}

private struct FilterStrip: View {
    let model: StoryEditorModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(StoryFilter.allCases) { f in
                let selected = model.doc.filter == f
                Button { model.setFilter(f) } label: {
                    VStack(spacing: 5) {
                        Group {
                            if let t = model.filterThumbs[f] {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.1)
                            }
                        }
                        .frame(width: 46, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white, lineWidth: selected ? 2 : 0))
                        Text(f.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .animation(Motion.slide, value: model.doc.filter)
    }
}

// MARK: - Trim

/// The video's frames with the kept part between two handles (at most 60 seconds), a
/// playhead, and the length kept.
private struct TrimBar: View {
    let model: StoryEditorModel
    let video: StoryVideo
    @State private var thumbs: [CGImage] = []
    @State private var dragging = false

    private let height: CGFloat = 46

    var body: some View {
        let total = max(model.duration, 0.1)
        VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                let x0 = CGFloat(model.doc.trimStart / total) * w, x1 = CGFloat(model.doc.trimEnd / total) * w
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(thumbs.indices, id: \.self) { i in
                            Image(decorative: thumbs[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(max(thumbs.count, 1)), height: height).clipped()
                        }
                    }
                    .frame(width: w, height: height)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // Outside the kept part: dimmed.
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, x0), height: height)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - x1), height: height).offset(x: x1)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: max(x1 - x0, 12), height: height)
                        .offset(x: x0)
                        .allowsHitTesting(false)
                    Playhead(video: video, total: total, width: w, height: height, hidden: dragging)
                    handle(x: x0, start: true, width: w, total: total)
                    handle(x: x1 - 12, start: false, width: w, total: total)
                }
            }
            .frame(height: height)
            .coordinateSpace(.named("trim"))
            HStack {
                Text(Self.time(model.doc.trimStart)).monospacedDigit()
                Spacer()
                Text("\(Self.time(model.doc.trimEnd - model.doc.trimStart)) of up to 0:60")
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(Self.time(model.doc.trimEnd)).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
        }
        .task(id: model.source?.url) {
            guard let s = model.source else { return }
            thumbs = await Self.frames(s, count: 10)
        }
    }

    private func handle(x: CGFloat, start: Bool, width: CGFloat, total: Double) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 14))
            .frame(width: 12, height: height)
            .offset(x: x)
            .contentShape(Rectangle().inset(by: -8))
            .pointerStyle(.frameResize(position: start ? .leading : .trailing))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                .onChanged { v in
                    if !dragging { dragging = true; model.beginGesture() }
                    let t = min(max(Double(v.location.x / width) * total, 0), total)
                    let limit = CreateMedia.maxStorySeconds, least = CreateMedia.minVideoSeconds
                    model.live { d in
                        if start {
                            d.trimStart = min(t, d.trimEnd - least)
                            if d.trimEnd - d.trimStart > limit { d.trimEnd = d.trimStart + limit }
                        } else {
                            d.trimEnd = max(t, d.trimStart + least)
                            if d.trimEnd - d.trimStart > limit { d.trimStart = d.trimEnd - limit }
                        }
                    }
                }
                .onEnded { _ in
                    dragging = false
                    model.endGesture()
                    video.setRange(model.doc.trimStart, model.doc.trimEnd)
                    video.play()
                })
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    @concurrent
    static func frames(_ source: CreateSource, count: Int) async -> [CGImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        let total = Double(source.durationMs ?? 0) / 1000
        var out: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: total * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { out.append(img) }
        }
        return out
    }
}

/// Only this redraws as the video plays.
private struct Playhead: View {
    let video: StoryVideo
    let total: Double
    let width: CGFloat
    let height: CGFloat
    let hidden: Bool

    var body: some View {
        Capsule().fill(.white)
            .frame(width: 3, height: height + 8)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: CGFloat(video.time / total) * width - 1.5, y: -4)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(false)
    }
}

// MARK: - Share

/// "Your story" at the bottom right, and the progress or error while sharing.
private struct ShareCorner: View {
    let model: StoryEditorModel
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            status
            if !model.isBusy {
                Button(action: model.share) {
                    HStack(spacing: 8) {
                        if let me = app.me { Avatar(url: me.avatar, size: 24) }
                        Text(failed ? "Try Again" : "Share to story").font(.system(size: 14, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.leading, app.me == nil ? 16 : 6)
                    .padding(.trailing, 14)
                    .frame(height: 40)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(model.editingText != nil)
                .help("Share to your story (⌘↩)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.pop, value: model.isBusy)
    }

    private var failed: Bool {
        if case .failed = model.export { return true }
        if case .failed = model.sharer?.phase { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        if case .rendering(let p) = model.export {
            progress("Preparing your story…", value: 0.15 * p)
        } else if let s = model.sharer, s.isSharing {
            progress(s.status, value: s.progress)
        } else if case .failed(let m) = model.export {
            failure(m)
        } else if case .failed(let m) = model.sharer?.phase {
            failure(m)
        }
    }

    private func progress(_ text: String, value: Double) -> some View {
        HStack(spacing: 12) {
            Spinner(size: 14)
            Text(text).font(.system(size: 13, weight: .medium))
            ProgressTrack(value: value).frame(width: 140)
            Button("Cancel", action: model.cancelShare).buttonStyle(DarkPillStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func failure(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.like)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't share").font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            .frame(maxWidth: 280, alignment: .leading)
        }
    }
}

// MARK: - Empty

/// Before a photo or video is chosen: drop one, or pick one.
private struct EmptyStoryPicker: View {
    let model: StoryEditorModel
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.storyGradient).opacity(0.9)
                    IGGlyph(icon: .media, size: 44).foregroundStyle(.white)
                }
                .frame(width: 96, height: 170)
                Text("Create a story").font(.system(size: 22, weight: .bold))
                Text("Drag a photo or a video here (up to a minute is kept).")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                if let notice = model.notice {
                    Text(notice).font(.system(size: 12.5)).foregroundStyle(Theme.like).multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                if model.loading {
                    Spinner(size: 18)
                } else {
                    Button("Select from computer", action: pick).buttonStyle(DarkPillStyle(prominent: true))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(.white.opacity(targeted ? 0.4 : 0.12))
                .padding(.horizontal, 160).padding(.top, 52).padding(.bottom, 40))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task {
                    if let url = await CreateSheet.urls(from: providers).first(where: CreateMedia.isMedia) { await model.load(url) }
                }
                return true
            }
            RoundTool(symbol: "xmark", label: "Close", action: close)
                .padding(.top, 52)
                .padding(.leading, 24)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "Choose a photo or video for your story"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.load(url) }
    }
}

/// Background choices: the picture blurred, its two colours, or one colour.
private struct BackgroundStrip: View {
    let model: StoryEditorModel

    var body: some View {
        HStack(spacing: 10) {
            swatch(.blur, label: "Blur") {
                if let image = model.backdropPreview, model.doc.background == .blur {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(cgColor: model.gradient.top.cg).opacity(0.7), Color(cgColor: model.gradient.bottom.cg)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blur(radius: 4)
                }
            }
            swatch(.gradient, label: "Colors") {
                LinearGradient(colors: [Color(cgColor: model.gradient.top.cg), Color(cgColor: model.gradient.bottom.cg)],
                               startPoint: .top, endPoint: .bottom)
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 34)
            ForEach(StoryColor.palette, id: \.self) { c in
                let selected = model.doc.background == .color(c)
                Button { model.setBackground(.color(c)) } label: {
                    Circle().fill(Color(cgColor: c.cg))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .scaleEffect(selected ? 1.25 : 1)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
            }
        }
        .animation(Motion.slide, value: model.doc.background)
    }

    private func swatch<Content: View>(_ b: StoryBackground, label: String, @ViewBuilder content: () -> Content) -> some View {
        let selected = model.doc.background == b
        return Button { model.setBackground(b) } label: {
            VStack(spacing: 5) {
                content()
                    .frame(width: 30, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.white : .white.opacity(0.25), lineWidth: selected ? 2 : 1))
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}
