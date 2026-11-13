import SwiftUI

/// A caption or comment with its #hashtags and @mentions as links, as Instagram shows them:
/// a hashtag opens its page, a mention the person's profile.
struct RichText: View {
    let text: String
    @Environment(AppModel.self) private var app

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.attributed(text))
            .tint(Theme.link)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme, let value = url.pathComponents.dropFirst().first else { return .systemAction }
                switch url.host() {
                case "tag": app.openHashtag(value)
                case "user": app.openProfile(username: value)
                default: return .systemAction
                }
                return .handled
            })
    }

    static let scheme = "matte-link"

    /// `#tag` (letters, digits, underscores, any script) and `@name` (letters, digits, `.`, `_`;
    /// not part of an email address, and without a trailing dot).
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = match.range
            var token = ns.substring(with: range)
            if token.hasPrefix("@") {
                while token.hasSuffix(".") { token.removeLast(); range.length -= 1 }
                // An email address: the "@" follows a word character.
                if range.location > 0, let prev = ns.substring(with: NSRange(location: range.location - 1, length: 1)).unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(prev) { continue }
            }
            guard token.count > 1, let r = Range(range, in: text),
                  let a = AttributedString.Index(r.lowerBound, within: out),
                  let b = AttributedString.Index(r.upperBound, within: out) else { continue }
            let kind = token.hasPrefix("#") ? "tag" : "user"
            let value = String(token.dropFirst()).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            out[a..<b].link = URL(string: "\(scheme)://\(kind)/\(value)")
        }
        return out
    }

    private static let pattern = try! NSRegularExpression(pattern: "#[\\p{L}\\p{N}_]+|@[A-Za-z0-9._]+")
}
