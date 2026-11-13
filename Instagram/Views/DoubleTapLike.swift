import SwiftUI
import AppKit

extension View {
    /// Double-click to like, as double-tap does on the phone. With `single`, a single click
    /// still does its own thing (open the post, pause the reel), a moment later, once it's clear
    /// no second click is coming; without it, only the double-click is handled.
    func doubleTapToLike(single: (() -> Void)? = nil, like: @escaping () -> Void) -> some View {
        modifier(DoubleTapLike(single: single, like: like))
    }
}

private struct DoubleTapLike: ViewModifier {
    let single: (() -> Void)?
    let like: () -> Void
    @State private var pending: Task<Void, Never>?
    @State private var lastTap = Date.distantPast

    /// The system's double-click time, but never so long that a plain click feels slow.
    private static var window: Double { min(NSEvent.doubleClickInterval, 0.28) }

    func body(content: Content) -> some View {
        if let single {
            content.onTapGesture {
                let now = Date.now
                if now.timeIntervalSince(lastTap) < Self.window, pending != nil {
                    pending?.cancel()
                    pending = nil
                    lastTap = .distantPast
                    like()
                    return
                }
                lastTap = now
                pending = Task {
                    try? await Task.sleep(for: .seconds(Self.window))
                    guard !Task.isCancelled else { return }
                    pending = nil
                    single()
                }
            }
        } else {
            content.onTapGesture(count: 2, perform: like)
        }
    }
}

/// A big heart that pops over a story or post and fades when you like it, so the like is unmistakable.
struct HeartBurst: View {
    let trigger: Int
    var size: CGFloat = 110

    var body: some View {
        IGGlyph(icon: .heartFilled, size: size)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 18)
            .keyframeAnimator(initialValue: BurstFrame(), trigger: trigger) { view, f in
                view.scaleEffect(f.scale).opacity(f.opacity).rotationEffect(.degrees(f.tilt))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.18)
                    CubicKeyframe(1.0, duration: 0.25)
                    CubicKeyframe(1.3, duration: 0.25)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.57)
                    CubicKeyframe(0, duration: 0.25)
                }
                KeyframeTrack(\.tilt) {
                    SpringKeyframe(-8, duration: 0.2)
                    SpringKeyframe(0, duration: 0.3)
                }
            }
            .allowsHitTesting(false)
    }

    struct BurstFrame {
        var scale: CGFloat = 0.2
        var opacity: Double = 0
        var tilt: Double = 0
    }
}

