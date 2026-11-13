import SwiftUI
import AppKit
import AVFoundation

/// The 9:16 canvas: gradient, the picture or video, the drawing, then text and stickers.
///
/// Gestures keep their in-between state here (`itemLive`, `bgLive`) and write the document
/// once when they end, so a drag redraws only the moving piece. Each piece is a ready-made
/// raster (`StoryEditorModel.image(for:)`), moved and turned by the compositor.
struct StoryCanvas: View {
    let model: StoryEditorModel
    let size: CGSize

    /// An item's place while it's being dragged, pinched or turned.
    private struct ItemLive: Equatable {
        var id: UUID
        var center: CGPoint
        var scale: CGFloat
        var rotation: Double
    }

    @State private var itemLive: ItemLive?
    @State private var itemBase: ItemLive?
    @State private var bgLive: (scale: CGFloat, offset: CGSize)?
    @State private var bgBase: (scale: CGFloat, offset: CGSize)?
    @State private var dragging: UUID?
    @State private var overTrash = false
    @State private var snapX = false
    @State private var snapY = false
    @Environment(\.displayScale) private var displayScale

    private var k: CGFloat { size.width / StoryDoc.size.width }
    private static let trash = CGPoint(x: StoryDoc.size.width / 2, y: StoryDoc.size.height - 150)

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            drawingLayer
            items
            guides
            if let id = model.selection, dragging == nil, model.mode == .normal,
               let item = model.doc.items.first(where: { $0.id == id }) {
                SelectionFrame(item: transform(item), box: model.image(for: item)?.box ?? .zero, k: k,
                               onHandle: { handle($0, item: item) }, onHandleEnd: { endItemGesture(item.id) })
            }
            if dragging != nil { trashZone }
            if let id = model.editingText { TextEditLayer(model: model, id: id, k: k, size: size) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .coordinateSpace(.named("canvas"))
        .simultaneousGesture(pinch)
        .onChange(of: size.width, initial: true) { _, w in
            model.setDisplayPPU(w / StoryDoc.size.width * displayScale)
        }
    }

    // MARK: Background

    private var bgRect: CGRect {
        var d = model.doc
        if let bgLive { d.bgScale = bgLive.scale; d.bgOffset = bgLive.offset }
        return d.bgRect(aspect: model.aspect)
    }

    private var background: some View {
        let r = bgRect
        return ZStack(alignment: .topLeading) {
            backdrop
            Group {
                if let video = model.video {
                    PlayerLayerView(player: video.player, gravity: .resize)
                } else if let image = model.filtered ?? model.display {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                }
            }
            .frame(width: r.width * k, height: r.height * k)
            .position(x: r.midX * k, y: r.midY * k)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, coordinateSpace: .local) { p in
            guard model.mode == .normal else { return }
            model.addText(at: CGPoint(x: p.x / k, y: p.y / k))
        }
        .onTapGesture(coordinateSpace: .local) { p in
            // Clicking a shared post's card switches its look, as tapping it does on the phone.
            if model.reshare != nil, model.mode == .normal, model.selection == nil,
               bgRect.contains(CGPoint(x: p.x / k, y: p.y / k)) {
                model.toggleCardStyle()
                return
            }
            model.selection = nil
            if model.mode == .filters || model.mode == .stickers || model.mode == .background { model.setMode(.normal) }
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                let base = bgBase ?? (model.doc.bgScale, model.doc.bgOffset)
                if bgBase == nil { bgBase = base; model.selection = nil }
                bgLive = (base.scale, CGSize(width: base.offset.width + v.translation.width / k,
                                             height: base.offset.height + v.translation.height / k))
            }
            .onEnded { _ in commitBackground() })
    }

    @ViewBuilder
    private var backdrop: some View {
        switch model.doc.background {
        case .color(let c):
            Color(cgColor: c.cg)
        case .blur:
            if let image = model.backdropPreview {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            } else {
                Color(cgColor: model.gradient.top.cg)
            }
        case .gradient:
            LinearGradient(colors: [Color(cgColor: model.gradient.top.cg), Color(cgColor: model.gradient.bottom.cg)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func commitBackground() {
        if let bgLive { model.commit { $0.bgScale = bgLive.scale; $0.bgOffset = bgLive.offset } }
        bgLive = nil
        bgBase = nil
    }

    // MARK: Drawing

    private var drawingLayer: some View {
        ZStack(alignment: .topLeading) {
            if let d = model.drawingImage {
                Image(decorative: d, scale: 1).resizable().frame(width: size.width, height: size.height)
            }
            if model.mode == .draw { DrawSurface(model: model, k: k, size: size) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // The eraser's live stroke cuts through the drawing below it.
        .compositingGroup()
        .allowsHitTesting(model.mode == .draw)
    }

    // MARK: Items

    private func transform(_ item: StoryItem) -> StoryItem {
        guard let l = itemLive, l.id == item.id else { return item }
        var t = item
        t.center = l.center
        t.scale = l.scale
        t.rotation = l.rotation
        return t
    }

    private var items: some View {
        ForEach(model.doc.items) { item in
            if item.id != model.editingText, let r = model.image(for: item) {
                let t = transform(item)
                let trashing = dragging == item.id && overTrash
                Image(decorative: r.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: r.size.width * k, height: r.size.height * k)
                    .contentShape(Rectangle().inset(by: r.inset * k))
                    .scaleEffect(t.scale * (trashing ? 0.35 : 1))
                    .rotationEffect(.radians(t.rotation))
                    .opacity(trashing ? 0.6 : 1)
                    .animation(Motion.pop, value: trashing)
                    .position(x: t.center.x * k, y: t.center.y * k)
                    .onTapGesture(count: 2) { if item.text != nil { model.editText(item.id) } }
                    .onTapGesture {
                        if model.mode != .normal { model.setMode(.normal) }
                        model.selection = item.id
                    }
                    .gesture(move(item))
                    .pointerStyle(dragging == item.id ? .grabActive : .grabIdle)
                    .allowsHitTesting(model.mode != .draw && model.editingText == nil)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private func move(_ item: StoryItem) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let base = itemBase ?? ItemLive(id: item.id, center: item.center, scale: item.scale, rotation: item.rotation)
                if itemBase == nil {
                    itemBase = base
                    dragging = item.id
                    if model.mode != .normal { model.setMode(.normal) }
                    model.selection = item.id
                }
                var c = CGPoint(x: base.center.x + v.translation.width / k, y: base.center.y + v.translation.height / k)
                let mid = StoryDoc.size
                let sx = abs(c.x - mid.width / 2) < 14, sy = abs(c.y - mid.height / 2) < 14
                if sx { c.x = mid.width / 2 }
                if sy { c.y = mid.height / 2 }
                if (sx && !snapX) || (sy && !snapY) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                snapX = sx
                snapY = sy
                let t = Self.trash
                let near = hypot(v.location.x / k - t.x, v.location.y / k - t.y) < 110
                if near != overTrash {
                    overTrash = near
                    if near { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                }
                itemLive = ItemLive(id: item.id, center: c, scale: base.scale, rotation: base.rotation)
            }
            .onEnded { _ in
                if overTrash {
                    withAnimation(Motion.pop) { model.delete(item.id) }
                    itemLive = nil
                    itemBase = nil
                } else {
                    endItemGesture(item.id)
                }
                dragging = nil
                overTrash = false
                snapX = false
                snapY = false
            }
    }

    private func endItemGesture(_ id: UUID) {
        if let l = itemLive, l.id == id {
            model.commit { d in
                guard let i = d.items.firstIndex(where: { $0.id == id }) else { return }
                d.items[i].center = l.center
                d.items[i].scale = l.scale
                d.items[i].rotation = l.rotation
            }
        }
        itemLive = nil
        itemBase = nil
    }

    /// The corner handle: distance from the centre scales, the angle turns.
    private func handle(_ location: CGPoint, item: StoryItem) {
        let base = itemBase ?? ItemLive(id: item.id, center: item.center, scale: item.scale, rotation: item.rotation)
        let box = model.image(for: item)?.box ?? CGSize(width: 100, height: 100)
        if itemBase == nil { itemBase = base }
        let start = CGPoint(x: box.width / 2 * base.scale, y: box.height / 2 * base.scale)
        let startAngle = atan2(start.y, start.x) + base.rotation
        let v = CGPoint(x: location.x / k - base.center.x, y: location.y / k - base.center.y)
        let scale = min(8, max(0.2, base.scale * hypot(v.x, v.y) / max(hypot(start.x, start.y), 1)))
        let rotation = Self.snapAngle(base.rotation + atan2(v.y, v.x) - startAngle)
        itemLive = ItemLive(id: item.id, center: base.center, scale: scale, rotation: rotation)
    }

    /// Turns near a right angle settle onto it.
    static func snapAngle(_ a: Double) -> Double {
        let q = (a / (.pi / 2)).rounded() * (.pi / 2)
        return abs(a - q) < 0.05 ? q : a
    }

    // MARK: Pinch and turn (trackpad)

    private var pinch: some Gesture {
        MagnifyGesture().simultaneously(with: RotateGesture())
            .onChanged { v in
                let m = v.first?.magnification ?? 1
                let turn = v.second?.rotation.radians ?? 0
                if let id = model.selection, let item = model.doc.items.first(where: { $0.id == id }) {
                    let base = itemBase ?? ItemLive(id: id, center: item.center, scale: item.scale, rotation: item.rotation)
                    if itemBase == nil { itemBase = base }
                    itemLive = ItemLive(id: id, center: base.center, scale: min(8, max(0.2, base.scale * m)),
                                        rotation: Self.snapAngle(base.rotation + turn))
                } else if model.hasMedia, model.mode == .normal || model.mode == .filters {
                    let base = bgBase ?? (model.doc.bgScale, model.doc.bgOffset)
                    if bgBase == nil { bgBase = base }
                    bgLive = (min(6, max(0.3, base.scale * m)), base.offset)
                }
            }
            .onEnded { _ in
                if let id = itemBase?.id { endItemGesture(id) }
                if bgBase != nil { commitBackground() }
            }
    }

    // MARK: Guides and trash

    private var guides: some View {
        ZStack {
            if snapX { Rectangle().fill(Color(red: 0.2, green: 0.75, blue: 1)).frame(width: 1.5, height: size.height).position(x: size.width / 2, y: size.height / 2) }
            if snapY { Rectangle().fill(Color(red: 0.2, green: 0.75, blue: 1)).frame(width: size.width, height: 1.5).position(x: size.width / 2, y: size.height / 2) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var trashZone: some View {
        let t = Self.trash
        return ZStack {
            Circle().fill(overTrash ? Color(red: 0.93, green: 0.29, blue: 0.34) : .black.opacity(0.35))
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
            Image(systemName: "trash").font(.system(size: overTrash ? 22 : 18, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: overTrash ? 64 : 50, height: overTrash ? 64 : 50)
        .position(x: t.x * k, y: t.y * k)
        .animation(Motion.pop, value: overTrash)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

// MARK: - Selection frame

/// A thin frame around the selected piece, with the scale-and-turn handle on its corner.
private struct SelectionFrame: View {
    let item: StoryItem
    let box: CGSize
    let k: CGFloat
    let onHandle: (CGPoint) -> Void
    let onHandleEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        let w = box.width * item.scale * k, h = box.height * item.scale * k
        let c = CGPoint(x: item.center.x * k, y: item.center.y * k)
        let cosA = cos(item.rotation), sinA = sin(item.rotation)
        let corner = CGPoint(x: c.x + (w / 2) * cosA - (h / 2) * sinA, y: c.y + (w / 2) * sinA + (h / 2) * cosA)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .frame(width: w, height: h)
                .rotationEffect(.radians(item.rotation))
                .position(c)
                .allowsHitTesting(false)
            Circle()
                .fill(.white)
                .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.black))
                .frame(width: hovering ? 24 : 20, height: hovering ? 24 : 20)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .position(corner)
                .onHover { hovering = $0 }
                .help("Drag to resize and rotate")
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { onHandle($0.location) }
                    .onEnded { _ in onHandleEnd() })
                .animation(Motion.slide, value: hovering)
        }
        .transition(.opacity)
    }
}

// MARK: - Drawing surface

/// Takes the pointer while drawing: the stroke in progress is drawn here (only this view
/// redraws as it grows) and added to the document, as one raster, when the mouse goes up.
private struct DrawSurface: View {
    let model: StoryEditorModel
    let k: CGFloat
    let size: CGSize
    @State private var points: [CGPoint] = []

    var body: some View {
        let stroke = StoryStroke(brush: model.brush, color: model.brushColor, width: StoryStroke.widths[model.brushWidth], points: points)
        Canvas { ctx, _ in
            guard !points.isEmpty else { return }
            ctx.scaleBy(x: k, y: k)
            let look = StoryRenderer.look(stroke)
            let path = Path(StoryRenderer.path(points))
            let style = StrokeStyle(lineWidth: look.width, lineCap: look.square ? .butt : .round, lineJoin: .round)
            if look.glow > 0 {
                var glow = ctx
                glow.addFilter(.shadow(color: Color(cgColor: look.color.cg), radius: look.glow * k / 2))
                glow.stroke(path, with: .color(Color(cgColor: look.color.cg)), style: style)
            } else {
                ctx.stroke(path, with: .color(Color(cgColor: look.color.cg)), style: style)
            }
            if let core = look.core {
                ctx.stroke(path, with: .color(Color(cgColor: core.cg)), style: StrokeStyle(lineWidth: look.width * 0.45, lineCap: .round, lineJoin: .round))
            }
        }
        .blendMode(model.brush == .eraser ? .destinationOut : .normal)
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = CGPoint(x: v.location.x / k, y: v.location.y / k)
                // Skip points closer than a unit or so: smoother curves, fewer points.
                if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 2 { return }
                points.append(p)
            }
            .onEnded { _ in
                model.addStroke(points)
                points = []
            })
        .pointerStyle(.rectSelection)
    }
}

// MARK: - Typing

/// While typing: the picture dims and the text is edited where Instagram puts it, in the
/// middle, in its style and colour.
private struct TextEditLayer: View {
    let model: StoryEditorModel
    let id: UUID
    let k: CGFloat
    let size: CGSize
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let t = model.draft
        let fontSize = t.style.size * k
        let fg = StoryRenderer.foreground(t)
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { model.finishText() }
            TextField("", text: $model.draft.string, prompt: Text("Type something…").foregroundStyle(.white.opacity(0.5)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Font(CTFontCreateCopyWithAttributes(StoryRenderer.font(t.style), fontSize, nil, nil)))
                .foregroundStyle(Color(cgColor: fg.cg))
                .multilineTextAlignment(t.alignment == .center ? .center : t.alignment == .left ? .leading : .trailing)
                .shadow(color: t.style == .neon ? Color(cgColor: t.color.cg) : .clear, radius: fontSize * 0.2)
                .padding(.horizontal, fontSize * 0.26)
                .padding(.vertical, fontSize * 0.1)
                .background {
                    if t.highlight != .none {
                        RoundedRectangle(cornerRadius: fontSize * 0.2, style: .continuous)
                            .fill(Color(cgColor: (t.highlight == .solid ? t.color : t.color.with(alpha: 0.5)).cg))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: StoryRenderer.textWrap * k)
                .focused($focused)
                .onSubmit { model.finishText() }
                .tint(Color(cgColor: t.color.cg))
        }
        .frame(width: size.width, height: size.height)
        .onAppear { focused = true }
        .transition(.opacity)
    }
}
