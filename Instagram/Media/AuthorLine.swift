import SwiftUI

/// Who posted it: one avatar and name, or for a collab post stacked avatars and
/// "owner and other" / "owner and 2 others" (the others listed on click), as Instagram does.
struct AuthorLine: View {
    let media: Media
    var avatarSize: CGFloat = 24
    var fontSize: CGFloat = 12.5
    /// Shown after the names (the post's age, say).
    var subtitle: String?
    @State private var showingOthers = false

    private var owner: User? { media.user }
    private var others: [User] { media.coauthors }

    var body: some View {
        HStack(spacing: 8) {
            avatars
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    name(owner)
                    if others.count == 1 {
                        Text("and").font(.system(size: fontSize)).foregroundStyle(.secondary)
                        name(others[0])
                    } else if others.count > 1 {
                        Text("and").font(.system(size: fontSize)).foregroundStyle(.secondary)
                        Button { showingOthers.toggle() } label: {
                            Text("\(others.count) others").font(.system(size: fontSize, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingOthers, arrowEdge: .bottom) { othersList }
                    }
                }
                .lineLimit(1)
                if media.suggested == true {
                    // Someone you don't follow, mixed into your feed by Instagram.
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: fontSize - 3, weight: .semibold))
                        Text("Suggested for you" + (subtitle.map { " · " + $0 } ?? ""))
                    }
                    .font(.system(size: fontSize - 1.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else if let subtitle {
                    Text(subtitle).font(.system(size: fontSize - 1)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var avatars: some View {
        ZStack(alignment: .bottomTrailing) {
            Avatar(url: owner?.avatar, size: others.isEmpty ? avatarSize : avatarSize * 0.78)
                .frame(width: avatarSize, height: avatarSize, alignment: .topLeading)
            if let second = others.first {
                Avatar(url: second.avatar, size: avatarSize * 0.62)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .opensProfile(owner)
    }

    @ViewBuilder
    private func name(_ user: User?) -> some View {
        if let user {
            HStack(spacing: 3) {
                Text(user.username).font(.system(size: fontSize, weight: .semibold))
                if user.isVerified { VerifiedBadge(size: fontSize * 0.8) }
            }
            .opensProfile(user)
        }
    }

    private var othersList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([owner].compactMap { $0 } + others) { user in
                HStack(spacing: 10) {
                    Avatar(url: user.avatar, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Text(user.username).font(.system(size: 13, weight: .semibold))
                            if user.isVerified { VerifiedBadge(size: 10) }
                        }
                        if !user.fullName.isEmpty {
                            Text(user.fullName).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .opensProfile(user)
            }
        }
        .padding(8)
        .frame(width: 240)
    }
}
