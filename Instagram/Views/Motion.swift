import SwiftUI
import AppKit

/// The app's motion: one set of springs and transitions so everything moves alike.
/// With "Reduce motion" on (System Settings → Accessibility), movement becomes short fades.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Pages and tabs.
    static var page: Animation { reduced ? .easeInOut(duration: 0.15) : .smooth(duration: 0.34) }
    /// A post or story growing out of where it was clicked.
    static var hero: Animation { reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.44, dampingFraction: 0.86) }
    /// Small things popping in: sheets, messages, menus.
    static var pop: Animation { reduced ? .easeInOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.78) }
    /// Selection highlights sliding between items.
    static var slide: Animation { reduced ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85) }
}

extension AnyTransition {
    /// A page pushed on top (a profile): slides in a little from the right while fading.
    static var push: AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(
            insertion: .offset(x: 48).combined(with: .opacity),
            removal: .offset(x: 48).combined(with: .opacity))
    }

    /// A sheet or palette: grows slightly from its centre while fading.
    static var pop: AnyTransition {
        Motion.reduced ? .opacity : .scale(scale: 0.94).combined(with: .opacity)
    }

    /// Moving between two items along an axis (reels up/down, stories left/right).
    static func step(_ edge: Edge, distance: CGFloat = 60) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        let (x, y): (CGFloat, CGFloat) = switch edge {
        case .top: (0, -distance)
        case .bottom: (0, distance)
        case .leading: (-distance, 0)
        case .trailing: (distance, 0)
        }
        return .asymmetric(insertion: .offset(x: x, y: y).combined(with: .opacity),
                           removal: .offset(x: -x, y: -y).combined(with: .opacity))
    }
}

extension View {
    /// A page that stays alive while hidden: fades and settles into place when shown.
    func pageVisibility(_ shown: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || Motion.reduced ? 1 : 0.985)
            .offset(y: shown || Motion.reduced ? 0 : 10)
            .allowsHitTesting(shown)
    }
}

extension EnvironmentValues {
    /// Shared by grids and the post viewer so a post grows out of its tile.
    @Entry var heroNamespace: Namespace.ID? = nil
    /// The post currently opened from a grid (its tile hides while the post is large).
    @Entry var heroOpened: String? = nil
}

extension View {
    /// Ties a tile and the opened post together for the open/close animation.
    @ViewBuilder
    func hero(_ id: String, in ns: Namespace.ID?, isSource: Bool = true) -> some View {
        if let ns, !Motion.reduced {
            matchedGeometryEffect(id: "hero-\(id)", in: ns, isSource: isSource)
        } else {
            self
        }
    }
}

/// A card that pops into place when it appears (its backdrop fades separately).
private struct PopIn: ViewModifier {
    var from: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || Motion.reduced ? 1 : from)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.pop) { shown = true } }
    }
}

extension View {
    func popIn(from scale: CGFloat = 0.94) -> some View { modifier(PopIn(from: scale)) }
}

/// Instagram's story cube: the account you're leaving turns away around one edge while the
/// next turns in around the other.
private struct CubeFace: ViewModifier {
    var angle: Double
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: anchor, perspective: 0.5)
            .opacity(abs(angle) >= 89 ? 0 : 1)
    }
}

extension AnyTransition {
    static func cube(forward: Bool) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: CubeFace(angle: forward ? 90 : -90, anchor: forward ? .leading : .trailing),
                                 identity: CubeFace(angle: 0, anchor: forward ? .leading : .trailing)),
            removal: .modifier(active: CubeFace(angle: forward ? -90 : 90, anchor: forward ? .trailing : .leading),
                               identity: CubeFace(angle: 0, anchor: forward ? .trailing : .leading)))
    }
}
