import SwiftUI

/// Emoji stickers: a curated grid, and search by name over every emoji the system draws.
struct StickerPicker: View {
    let model: StoryEditorModel
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { model.setMode(.normal) }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        IGGlyph(icon: .search, size: 14).foregroundStyle(.white.opacity(0.55))
                        TextField("", text: $query, prompt: Text("Search emoji").foregroundStyle(.white.opacity(0.45)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($searching)
                            .onSubmit { if let first = results.first { model.addSticker(first) } }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
                    Button { model.setMode(.normal) } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.pressable)
                    .help("Close (Esc)")
                }
                .padding(14)
                ScrollView {
                    if results.isEmpty {
                        Text("No emoji match “\(query)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).padding(30)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: 8), spacing: 4) {
                        ForEach(results, id: \.self) { e in
                            EmojiCell(emoji: e) { model.addSticker(e) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.never)
            }
            .frame(width: 480, height: 460)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .popIn()
        }
        .onAppear { searching = true }
    }

    private var results: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return EmojiCatalog.featured }
        return EmojiCatalog.search(q)
    }
}

private struct EmojiCell: View {
    let emoji: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 34))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.12 : 0)))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// The emoji on offer: a hand-picked first page, and every single-character emoji with its
/// Unicode name for search.
nonisolated enum EmojiCatalog {
    static let featured: [String] = Array(
        "❤️😂😍🥹🔥✨🎉👏🙌💯😭🥰😎🤩😘😅🙏💕🤍🖤💙💚💛🧡💜🩷😊😇🤗🤔🫶👀💪👍✌️🤞👋🙈😴🥳🤯😱😬🙃😉😜🤪😋☕️🍕🍔🍦🍩🍓🥑🍾🥂🍻🎂🎁🎈🎶🎧📸🎬📍✈️🏖️🌴🌊🌅🌙⭐️☀️🌈🌸🌻🌹🍂❄️⚡️💫🐶🐱🦋🐝🦄🏀⚽️🏆🚀💡📚💻🎮🛍️💐🕶️👑💎"
    ).map(String.init)

    /// Every emoji drawn as an emoji by default, with its name in lower case.
    static let all: [(emoji: String, name: String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF]
        for range in ranges {
            for v in range {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let name = s.properties.name else { continue }
                out.append((String(Character(s)), name.lowercased()))
            }
        }
        return out
    }()

    static func search(_ q: String) -> [String] {
        let words = q.split(separator: " ").map(String.init)
        return all.filter { e in words.allSatisfy { e.name.contains($0) } }.map(\.emoji)
    }
}
