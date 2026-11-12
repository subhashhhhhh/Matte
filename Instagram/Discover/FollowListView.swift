import SwiftUI

/// Followers or following, as a panel over the profile. Each person opens their profile
/// (Back returns here, with the list still open).
struct FollowListPanel: View {
    let model: FollowListModel
    let close: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                ZStack {
                    Text(model.title).font(.system(size: 15, weight: .semibold))
                    HStack {
                        Spacer()
                        ChromeButton("Close", symbol: "xmark", action: close)
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 48)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                list
            }
            .frame(width: 420, height: 560)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.panelStroke))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
        .task { await model.loadMore() }
    }

    @ViewBuilder
    private var list: some View {
        if model.users.isEmpty {
            Group {
                if !model.settled || model.isLoading {
                    Spinner(size: 20)
                } else if model.failed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load this list")
                } else {
                    EmptyState(symbol: "person.2", title: model.followers ? "No followers yet" : "Not following anyone")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.users) { user in
                        FollowRow(user: user, followsYou: model.followsYou(user)) { app.openProfile(user) }
                            .onAppear { model.appeared(user) }
                    }
                    if model.isLoading {
                        Spinner().padding(16)
                    } else if !model.hasMore, !model.isMine {
                        Text("Instagram shows only part of other people's lists.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(16)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct FollowRow: View {
    let user: User
    let followsYou: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Avatar(url: user.avatar, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(user.username).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if user.isVerified { VerifiedBadge(size: 12) }
                    }
                    if !user.fullName.isEmpty {
                        Text(user.fullName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if followsYou {
                    Text("Follows you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.panel))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
