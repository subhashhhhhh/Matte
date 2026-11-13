import SwiftUI

/// The signed-out screen: Matte's name, what it is, and signing in, over a slow, soft glow in
/// Instagram's warm colours. Sign-in happens on Instagram's own page (the sheet).
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.background
            WelcomeGlow()
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                VStack(spacing: 10) {
                    Text("Matte")
                        .font(.custom("SnellRoundhand-Black", size: 92))
                        .padding(.horizontal, 20)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                    Text("Instagram, made for the Mac.")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .offset(y: appeared ? 0 : 12)
                VStack(alignment: .leading, spacing: 18) {
                    Feature(icon: .direct, title: "Messages, live",
                            detail: "Real-time chats with reactions, replies, voice notes and shared posts.")
                    Feature(icon: .reels, title: "Reels, stories and your feed",
                            detail: "Everything plays in place, and slips into a mini player when you move on.")
                    Feature(icon: .heart, title: "Light on your Mac",
                            detail: "A fraction of the memory instagram.com takes in a browser.")
                }
                .frame(maxWidth: 400)
                .padding(.top, 44)
                .offset(y: appeared ? 0 : 18)
                Spacer(minLength: 40)
                VStack(spacing: 14) {
                    Button { app.showSignIn = true } label: {
                        Text("Sign in with Instagram")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 260, height: 44)
                    }
                    .buttonStyle(WelcomeButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    Text("\(Image(systemName: "lock.fill"))  You sign in on Instagram's own page. Your session stays on this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 48)
                .offset(y: appeared ? 0 : 24)
            }
            .opacity(appeared ? 1 : 0)
            .padding(.horizontal, 40)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(Motion.reduced ? .easeOut(duration: 0.2) : .smooth(duration: 0.9)) { appeared = true }
        }
    }
}

private struct Feature: View {
    let icon: IGIcon
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            IGGlyph(icon: icon, size: 22)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().strokeBorder(Theme.panelStroke))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }
}

/// The sign-in button: Instagram's gradient, softly lit, a small press.
private struct WelcomeButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(LinearGradient(colors: WelcomeGlow.colors, startPoint: .leading, endPoint: .trailing))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: WelcomeGlow.colors[1].opacity(configuration.isPressed ? 0.2 : 0.4), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(hovering ? 0.05 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Three blurred lights in Instagram's colours drifting slowly behind the page (still when
/// Reduce Motion is on).
private struct WelcomeGlow: View {
    static let colors: [Color] = [
        Color(red: 0.99, green: 0.58, blue: 0.30),
        Color(red: 0.89, green: 0.21, blue: 0.48),
        Color(red: 0.51, green: 0.25, blue: 0.86),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Motion.reduced)) { context in
            let t = Motion.reduced ? 0 : context.date.timeIntervalSinceReferenceDate / 9
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Self.colors[0], size: w * 0.55, x: w * (0.3 + 0.08 * sin(t)), y: h * (0.28 + 0.06 * cos(t * 0.8)))
                    blob(Self.colors[1], size: w * 0.6, x: w * (0.68 + 0.07 * cos(t * 0.9)), y: h * (0.4 + 0.07 * sin(t * 1.1)))
                    blob(Self.colors[2], size: w * 0.5, x: w * (0.5 + 0.1 * sin(t * 0.7)), y: h * (0.72 + 0.05 * cos(t)))
                }
                .blur(radius: 120)
                .opacity(0.26)
            }
        }
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size).position(x: x, y: y)
    }
}
