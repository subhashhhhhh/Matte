import SwiftUI
import AppKit

/// The app's own look, after Velvet's: neutral surfaces built from the text colour at low
/// opacity, continuous corners, soft hover states, and colour only where it means something
/// (links, a like, a repost). No system controls are drawn with their stock appearance.
enum Theme {
    /// The window's background: a touch warmer than pure black or white.
    static let background = Color(nsColor: NSColor(name: "IGBackground") { a in
        a.isDark ? NSColor(srgbRed: 0.075, green: 0.075, blue: 0.082, alpha: 1)
                 : NSColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1)
    })

    /// Panels that float above the background (sidebar, cards, the composer).
    static let panel = Color.primary.opacity(0.045)
    static let panelStroke = Color.primary.opacity(0.07)
    static let hairline = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.05)
    static let selected = Color.primary.opacity(0.1)
    static let placeholder = Color.primary.opacity(0.08)

    /// Links, mentions, hashtags.
    static let link = Color(nsColor: NSColor(name: "IGLink") { a in
        a.isDark ? NSColor(srgbRed: 0.42, green: 0.74, blue: 1.0, alpha: 1)
                 : NSColor(srgbRed: 0.05, green: 0.45, blue: 0.82, alpha: 1)
    })
    static let like = Color(nsColor: NSColor(name: "IGLike") { a in
        a.isDark ? NSColor(srgbRed: 1.0, green: 0.36, blue: 0.48, alpha: 1)
                 : NSColor(srgbRed: 0.88, green: 0.11, blue: 0.33, alpha: 1)
    })
    static let repost = Color(nsColor: NSColor(name: "IGRepost") { a in
        a.isDark ? NSColor(srgbRed: 0.2, green: 0.83, blue: 0.6, alpha: 1)
                 : NSColor(srgbRed: 0.0, green: 0.6, blue: 0.4, alpha: 1)
    })
    static let bookmark = link

    /// The app's accent is neutral: near-white in dark mode, near-black in light.
    static let accent = Color("AccentColor")

    static let cornerRadius: CGFloat = 14
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Buttons

/// A round, borderless icon button that shows a soft circle on hover.
struct ChromeButton: View {
    let label: String
    let symbol: String
    var shortcut: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void

    init(_ label: String, symbol: String, shortcut: KeyEquivalent? = nil, modifiers: EventModifiers = .command,
         action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.shortcut = shortcut
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ChromeButtonStyle())
            .help(label)
            .accessibilityLabel(label)
            .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: modifiers) })
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, size: size)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// The main button of a view (Sign In, Post, Follow…): filled with the text colour.
struct ProminentButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .padding(.horizontal, compact ? 14 : 18)
            .frame(height: compact ? 30 : 36)
            .foregroundStyle(Theme.background)
            .background(Capsule().fill(.primary))
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

/// A quieter button: a soft fill that deepens on hover (Cancel, Following…).
struct SecondaryPillStyle: ButtonStyle {
    var compact = true

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, compact: compact)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .padding(.horizontal, compact ? 14 : 18)
                .frame(height: compact ? 30 : 36)
                .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : 0.07)))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A plain button that only dims while pressed, for text and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
    static var prominentCompact: ProminentButtonStyle { ProminentButtonStyle(compact: true) }
}

extension ButtonStyle where Self == SecondaryPillStyle {
    static var secondaryPill: SecondaryPillStyle { SecondaryPillStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Tabs

/// Tabs that split the width evenly, with a soft highlight that slides to the selected one.
struct SegmentedTabs<Value: Hashable>: View {
    let tabs: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.value) { tab in
                let selected = tab.value == selection
                Button { selection = tab.value } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.primary.opacity(0.11))
                                    .matchedGeometryEffect(id: "tab", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.05)))
        .animation(.smooth(duration: 0.25), value: selection)
    }
}

// MARK: - Small pieces

/// A thin rotating arc, in place of the system's progress indicator.
struct Spinner: View {
    var size: CGFloat = 18
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.secondary, style: StrokeStyle(lineWidth: max(1.5, size / 9), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel("Loading")
    }
}

/// A round avatar, loaded at the size it's shown.
struct Avatar: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
    }
}

/// The blue check, drawn rather than taken from the system's symbol set colour.
struct VerifiedBadge: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .foregroundStyle(Theme.link)
            .accessibilityLabel("Verified")
    }
}

/// A message and an optional action, for empty or failed pages.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.prominentCompact)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Numbers and dates

extension Int {
    /// 1234 → "1.2K", 1_250_000 → "1.2M", as Instagram shows counts.
    var compact: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

extension Date {
    /// "now", "5m", "3h", then "Mar 4", then "Mar 4, 2023", as Instagram shows times.
    var shortAge: String {
        let s = Date.now.timeIntervalSince(self)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        let sameYear = Calendar.current.isDate(self, equalTo: .now, toGranularity: .year)
        return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
