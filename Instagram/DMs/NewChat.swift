import SwiftUI

/// "New message": search anyone on Instagram and open (or start) a chat with them.
struct NewMessageSheet: View {
    let close: () -> Void
    var initialQuery = ""
    let pick: (User) -> Void
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [User] = []
    @State private var searching = false
    @State private var sessionId = UUID().uuidString.lowercased()
    @FocusState private var focused: Bool

    /// People from your chats that match, shown before (and above) search results.
    private var fromChats: [User] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let people = (app.inbox?.threads ?? []).filter { !$0.isGroup }.compactMap(\.users.first)
        guard !q.isEmpty else { return people }
        return people.filter { $0.username.lowercased().contains(q) || $0.fullName.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack {
                    Text("New message").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.pressable)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Text("To:").font(.system(size: 14, weight: .semibold))
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { if let first = (fromChats + results).first { pick(first) } }
                    if searching { Spinner(size: 12) }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let chats = fromChats
                        if !chats.isEmpty {
                            section(query.isEmpty ? "Your chats" : "From your chats")
                            ForEach(chats) { row($0) }
                        }
                        let others = results.filter { r in !chats.contains { $0.id == r.id } }
                        if !others.isEmpty {
                            section("More accounts")
                            ForEach(others) { row($0) }
                        }
                        if chats.isEmpty, others.isEmpty, !query.isEmpty, !searching {
                            Text("No account found.").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(30)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
            }
            .frame(width: 420, height: 520)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.3), radius: 30)
        }
        .onAppear {
            focused = true
            if query.isEmpty { query = initialQuery }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, let client = app.client else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            if let r = try? await client.search(q, sessionId: sessionId), !Task.isCancelled { results = r.users }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ user: User) -> some View {
        HoverRow {
            HStack(spacing: 12) {
                Avatar(url: user.avatar, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(user.username).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if user.isVerified { VerifiedBadge(size: 11) }
                    }
                    if !user.fullName.isEmpty {
                        Text(user.fullName).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .onTapGesture { pick(user) }
    }
}

/// A row with a soft highlight on hover.
private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A chat with someone you've never messaged: their card, and a box for the first message.
struct NewChatView: View {
    let model: InboxModel
    let user: User
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(url: user.avatar, size: 34)
                Text(user.username).font(.system(size: 14, weight: .semibold))
                Spacer()
                ChromeButton("Close", symbol: "xmark") { model.cancelNewChat() }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(spacing: 8) {
                Spacer()
                Avatar(url: user.avatar, size: 96)
                    .opensProfile(user)
                HStack(spacing: 4) {
                    Text(user.displayName).font(.system(size: 18, weight: .bold))
                    if user.isVerified { VerifiedBadge(size: 14) }
                }
                Text(user.username + " · Instagram").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Say hi: your first message starts the chat.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer()
                if sending { Spinner(size: 16).padding(.bottom, 8) }
            }
            .frame(maxWidth: .infinity)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 9)
                    .disabled(sending)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Send", action: send)
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.link)
                        .padding(.bottom, 9)
                        .disabled(sending)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.panelStroke, lineWidth: 1.5))
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard !sending else { return }
        let text = draft
        sending = true
        Task {
            if await model.sendFirstMessage(text) { draft = "" }
            sending = false
        }
    }
}

/// Under a message request, in place of the message box: accept it to reply.
struct RequestBar: View {
    let model: ConversationModel
    @State private var accepting = false

    var body: some View {
        VStack(spacing: 10) {
            Text(model.thread.isGroup
                 ? "You've been invited to this group chat. Accept to reply and let them know you've seen it."
                 : "\(model.thread.users.first?.username ?? "This account") wants to send you a message. They won't know you've seen it until you accept.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                accepting = true
                Task {
                    await model.acceptRequest()
                    accepting = false
                }
            } label: {
                Text(accepting ? "Accepting…" : "Accept").frame(width: 160)
            }
            .buttonStyle(.prominent)
            .disabled(accepting)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
