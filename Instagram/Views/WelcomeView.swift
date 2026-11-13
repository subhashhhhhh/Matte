import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// The signed-out screen, after a darkroom: warm black, fine film grain, one dim safelight
/// falling from the top, and the name developing like a print. Colours come from photo paper
/// (Matte is a paper finish), not a gradient generator: one temperature, one light, one accent.
/// Sign-in happens on Instagram's own page (the sheet).
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    /// The safelight comes on, then the print develops, then the rest settles in.
    @State private var light: Bool
    @State private var developed: Bool
    @State private var settled: Bool

    /// `animated: false` starts finished (renders, screenshots).
    init(animated: Bool = true) {
        _light = State(initialValue: !animated)
        _developed = State(initialValue: !animated)
        _settled = State(initialValue: !animated)
    }

    var body: some View {
        ZStack {
            Darkroom.black
            Safelight().opacity(light ? 1 : 0)
            FilmGrain()
            VStack(spacing: 0) {
                Spacer(minLength: 36)
                VStack(spacing: 14) {
                    Text("Matte")
                        .font(.custom("SnellRoundhand-Black", size: 96))
                        .foregroundStyle(Darkroom.paper)
                        .padding(.horizontal, 24)
                        .blur(radius: developed ? 0 : 10)
                        .opacity(developed ? 1 : 0)
                    VStack(spacing: 6) {
                        Text("Your Instagram, on the big screen.")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Darkroom.paper)
                        Text("Made for the desktop, not a phone app stretched to fit.")
                            .font(.system(size: 14))
                            .foregroundStyle(Darkroom.muted)
                    }
                    .opacity(settled ? 1 : 0)
                    .offset(y: settled ? 0 : 8)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Point(icon: .home, title: "Your feed, laid out for a wide screen",
                          detail: "Posts in columns across the window, with stories at the side.")
                    Point(icon: .direct, title: "Chat without picking up your phone",
                          detail: "Messages arrive the moment they're sent, right beside whatever you're doing.")
                    Point(icon: .reels, title: "Reels and stories, big and clear",
                          detail: "Watch them full size, and keep one playing in the corner while you browse.")
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 46)
                .opacity(settled ? 1 : 0)
                .offset(y: settled ? 0 : 12)
                Spacer(minLength: 36)
                VStack(spacing: 14) {
                    Button { app.showSignIn = true } label: {
                        Text("Sign in with Instagram")
                            .font(.system(size: 14.5, weight: .semibold))
                            .frame(width: 250, height: 42)
                    }
                    .buttonStyle(PaperButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    Text("\(Image(systemName: "lock.fill"))  You sign in on Instagram's own page. Your login stays on this Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Darkroom.faint)
                }
                .padding(.bottom, 46)
                .opacity(settled ? 1 : 0)
            }
            .padding(.horizontal, 40)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onAppear(perform: reveal)
    }

    private func reveal() {
        guard !settled else { return }
        guard !Motion.reduced else { light = true; developed = true; settled = true; return }
        withAnimation(.easeOut(duration: 1.2)) { light = true }
        withAnimation(.easeOut(duration: 1.4).delay(0.35)) { developed = true }
        withAnimation(.smooth(duration: 0.8).delay(1.0)) { settled = true }
    }
}

/// Photo-paper colours: warm black, the paper's off-white and its greys, and the safelight.
enum Darkroom {
    static let black = Color(red: 0.067, green: 0.059, blue: 0.055)
    static let paper = Color(red: 0.93, green: 0.90, blue: 0.85)
    static let muted = Color(red: 0.93, green: 0.90, blue: 0.85).opacity(0.62)
    static let faint = Color(red: 0.93, green: 0.90, blue: 0.85).opacity(0.36)
    /// A darkroom safelight's amber-red, kept very dim.
    static let safelight = Color(red: 0.86, green: 0.36, blue: 0.20)
}

private struct Point: View {
    let icon: IGIcon
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            IGGlyph(icon: icon, size: 21)
                .foregroundStyle(Darkroom.paper.opacity(0.85))
                .frame(width: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Darkroom.paper)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Darkroom.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Flat photo-paper white with warm-black type: no gradient, no glow.
private struct PaperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaperButton(configuration: configuration)
    }

    private struct PaperButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Darkroom.black)
                .background(Capsule().fill(Darkroom.paper.opacity(hovering ? 1 : 0.94)))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// One dim light from above (a single hue fading into the black) and darker corners, as a
/// darkroom lit by its safelight.
private struct Safelight: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RadialGradient(colors: [Darkroom.safelight.opacity(0.22), Darkroom.safelight.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.5, y: -0.08), startRadius: 0, endRadius: max(w, h) * 0.75)
                // Vignette: the room's corners fall away.
                RadialGradient(colors: [.clear, .black.opacity(0.45)],
                               center: .center, startRadius: min(w, h) * 0.35, endRadius: max(w, h) * 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Fine, still film grain over everything (made once, tiled).
struct FilmGrain: View {
    private static let tile: CGImage? = {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        return noise.flatMap { context.createCGImage($0, from: CGRect(x: 0, y: 0, width: 256, height: 256)) }
    }()

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.10)
                .allowsHitTesting(false)
        }
    }
}
