import SwiftUI

/// The bar across the top: the wordmark, search, and your profile. Doubles as the window's
/// title bar (drag it to move the window).
struct TopBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            if !app.profiles.isEmpty {
                ChromeButton("Back", symbol: "chevron.left", shortcut: "[") { app.closeProfile() }
            }
            Text("Matte")
                .font(.custom("SnellRoundhand-Black", size: 30))
                .padding(.top, 2)
                .fixedSize()
                .onTapGesture { app.destination = .home }
                .help("Home")
            Spacer(minLength: 20)
            if let search = app.search {
                SearchField(model: search)
                    .frame(maxWidth: 420)
            }
            Spacer(minLength: 20)
            if let activity = app.activity {
                @Bindable var activity = activity
                Button { activity.isOpen.toggle() } label: {
                    IGGlyph(icon: activity.isOpen ? .heartFilled : .heart, size: 22)
                        .frame(width: 32, height: 32)
                        .overlay(alignment: .topTrailing) {
                            if activity.unseen > 0 {
                                Circle().fill(Theme.like).frame(width: 8, height: 8).offset(x: -3, y: 4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("Notifications")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background {
            Theme.background
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// The search box and, while typing, a panel of people and hashtags under it.
private struct SearchField: View {
    @Bindable var model: SearchModel
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        HStack(spacing: 8) {
            IGGlyph(icon: .search, size: 15).foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { openHighlighted() }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, rows - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { model.clear(); focused = false; return .handled }
            if model.isSearching { Spinner(size: 12) }
            if !model.query.isEmpty {
                Button { model.clear() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Theme.selected : .clear))
        .overlay(alignment: .topLeading) {
            if focused, !model.query.isEmpty, !model.isEmpty {
                results
                    .offset(y: 42)
                    .transition(.opacity)
            }
        }
        .background {
            // ⌘F jumps to search; ⌘K opens the quick switcher.
            Group {
                Button("") { focused = true }.keyboardShortcut("f")
                Button("") { app.showSwitcher = true }.keyboardShortcut("k")
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onChange(of: model.query) { highlighted = 0 }
        .onChange(of: focused) { if focused { model.sessionId = UUID().uuidString.lowercased() } }
    }

    private var rows: Int { min(model.results.users.count, 8) + min(model.results.hashtags.count, 4) }

    private var results: some View {
        let users = Array(model.results.users.prefix(8))
        let tags = Array(model.results.hashtags.prefix(4))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(users.enumerated()), id: \.element.id) { i, user in
                row(i) {
                    StoryRing(seen: user.latestStory == nil, lineWidth: 2) { Avatar(url: user.avatar, size: 34) }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(user.username).font(.system(size: 13.5, weight: .semibold))
                            if user.isVerified { VerifiedBadge(size: 11) }
                        }
                        if !user.fullName.isEmpty {
                            Text(user.fullName).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                } action: { open(user) }
            }
            if !tags.isEmpty, !users.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
            }
            ForEach(Array(tags.enumerated()), id: \.element.id) { j, tag in
                row(users.count + j) {
                    Text("#").font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().strokeBorder(Theme.panelStroke))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("#\(tag.name)").font(.system(size: 13.5, weight: .semibold))
                        if let n = tag.mediaCount { Text("\(n.compact) posts").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                } action: { open(tag) }
            }
        }
        .padding(6)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func row<Content: View>(_ index: Int, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) { content(); Spacer(minLength: 0) }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(index == highlighted ? Theme.selected : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { if $0 { highlighted = index } }
    }

    private func openHighlighted() {
        let users = Array(model.results.users.prefix(8))
        if users.indices.contains(highlighted) { open(users[highlighted]); return }
        let j = highlighted - users.count
        let tags = Array(model.results.hashtags.prefix(4))
        if tags.indices.contains(j) { open(tags[j]) }
    }

    private func open(_ user: User) {
        app.openProfile(user)
        model.clear()
        focused = false
    }

    private func open(_ tag: Hashtag) {
        app.openHashtag(tag.name)
        model.clear()
        focused = false
    }
}
