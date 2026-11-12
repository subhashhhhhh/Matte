import SwiftUI

/// ⌘K: type to jump to a chat, a person or a page.
struct QuickSwitcher: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var people: [User] = []
    @State private var highlighted = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private enum Item: Identifiable {
        case page(Destination)
        case notifications
        case me(User)
        case chat(DMThread)
        case person(User)

        var id: String {
            switch self {
            case .page(let d): "page-\(d.rawValue)"
            case .notifications: "notifications"
            case .me: "me"
            case .chat(let t): "chat-\(t.id)"
            case .person(let u): "person-\(u.id)"
            }
        }
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Item] = []
        let pages: [Item] = app.destinations.map { .page($0) } + [.notifications] + (app.me.map { [.me($0)] } ?? [])
        out += pages.filter { q.isEmpty || title(of: $0).lowercased().contains(q) }
        let chats = (app.inbox?.threads ?? []).filter { t in
            q.isEmpty || t.title.lowercased().contains(q) || t.users.contains { $0.username.lowercased().contains(q) }
        }
        out += chats.prefix(q.isEmpty ? 5 : 8).map { .chat($0) }
        let chatUsers = Set(chats.flatMap { $0.users.map(\.id) })
        out += people.filter { !chatUsers.contains($0.id) }.prefix(8).map { .person($0) }
        return out
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IGGlyph(icon: .search, size: 16).foregroundStyle(.secondary)
                    TextField("Jump to a chat, person or page", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { open(at: highlighted) }
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, items.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == highlighted)
                                .onTapGesture { open(at: i) }
                                .onHover { if $0 { highlighted = i } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .scrollIndicators(.never)
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
            .popIn(from: 0.95)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) {
            highlighted = 0
            searchTask?.cancel()
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2, let client = app.client else { people = []; return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                let found = (try? await client.search(q, sessionId: UUID().uuidString.lowercased()).users) ?? []
                if !Task.isCancelled { people = found }
            }
        }
    }

    private func title(of item: Item) -> String {
        switch item {
        case .page(let d): d.title
        case .notifications: "Notifications"
        case .me: "Your profile"
        case .chat(let t): t.title
        case .person(let u): u.username
        }
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case .page(let d):
                IGGlyph(icon: d.glyph.outline, size: 18).frame(width: 32, height: 32)
                Text(d.title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text("⌘\(String(d.shortcut.character))").font(.system(size: 12)).foregroundStyle(.secondary)
            case .notifications:
                IGGlyph(icon: .heart, size: 18).frame(width: 32, height: 32)
                Text("Notifications").font(.system(size: 14, weight: .medium))
                Spacer()
            case .me(let u):
                Avatar(url: u.avatar, size: 32)
                Text("Your profile").font(.system(size: 14, weight: .medium))
                Spacer()
            case .chat(let t):
                ThreadAvatar(thread: t, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("Chat").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            case .person(let u):
                Avatar(url: u.avatar, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(u.username).font(.system(size: 14, weight: .medium))
                        if u.isVerified { VerifiedBadge(size: 11) }
                    }
                    if !u.fullName.isEmpty { Text(u.fullName).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }

    private func open(at index: Int) {
        let list = items
        guard list.indices.contains(index) else { return }
        close()
        switch list[index] {
        case .page(let d): app.destination = d
        case .notifications: app.activity?.isOpen = true
        case .me(let u): app.openProfile(u)
        case .chat(let t): app.openChat(t.id)
        case .person(let u): app.openProfile(u)
        }
    }

    private func close() { app.showSwitcher = false }
}
