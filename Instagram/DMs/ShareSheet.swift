import SwiftUI

/// "Send to…": pick one or more chats, add a message if you like, send. The post goes as a
/// real share (a card in the chat), the message as a text after it, as the web app does.
struct ShareSheet: View {
    let media: Media
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selected: [String] = []
    @State private var message = ""
    @State private var sending = false
    @FocusState private var searchFocused: Bool

    /// A story item (it expires) goes as a story share.
    private var isStory: Bool { media.expiresAt != nil }

    private var threads: [DMThread] {
        let all = app.inbox?.threads ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { t in
            t.title.lowercased().contains(q) || t.users.contains { $0.username.lowercased().contains(q) }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.hairline).frame(height: 1)
                search
                list
                Rectangle().fill(Theme.hairline).frame(height: 1)
                footer
            }
            .frame(width: 420, height: 560)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.3), radius: 30)
            .popIn()
        }
        .task { await app.inbox?.loadIfNeeded() }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RemoteImage(url: media.image(minWidth: 80), contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Send to").font(.system(size: 15, weight: .bold))
                if let u = media.user?.username {
                    Text("\(isStory ? "Story" : media.productType == "clips" ? "Reel" : "Post") by \(u)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isStory {
                Button { app.addToStory(media) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 13))
                        Text("Add to story").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.panel))
                    .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .help("Add this \(media.productType == "clips" ? "reel" : "post") to your story")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .padding(12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(threads) { thread in
                    let isSelected = selected.contains(thread.id)
                    HStack(spacing: 12) {
                        ThreadAvatar(thread: thread, size: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(thread.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if !thread.isGroup, let u = thread.users.first, u.username != thread.title {
                                Text(u.username).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        ZStack {
                            Circle().strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.3), lineWidth: 1.5)
                            if isSelected {
                                Circle().fill(Theme.link)
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.selected : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelected { selected.removeAll { $0 == thread.id } } else { selected.append(thread.id) }
                    }
                }
                if threads.isEmpty {
                    Text(app.inbox?.threads.isEmpty == false ? "No chats match" : "Loading chats…")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(30)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !selected.isEmpty {
                TextField("Write a message…", text: $message)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
                    .onSubmit { Task { await send() } }
            }
            Button {
                Task { await send() }
            } label: {
                Text(sending ? "Sending…" : selected.count > 1 ? "Send separately" : "Send")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.link.opacity(selected.isEmpty || sending ? 0.4 : 1)))
            }
            .buttonStyle(.pressable)
            .disabled(selected.isEmpty || sending)
        }
        .padding(12)
    }

    private func send() async {
        guard !selected.isEmpty, !sending, let client = app.client else { return }
        sending = true
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var failures = 0
        for id in selected {
            do {
                // A one-to-one chat goes to the person (recorded: `recipient_users` and no thread);
                // a group to the chat.
                let thread = app.inbox?.threads.first { $0.id == id }
                let target: IGClient.ShareTarget = if let t = thread, !t.isGroup, t.users.count == 1, let u = t.users.first {
                    .user(u.id)
                } else {
                    .thread(id)
                }
                if isStory, let owner = media.user?.id {
                    try await client.shareStory(media, reelId: owner, to: target)
                } else {
                    try await client.share(media, to: target)
                }
                if !text.isEmpty {
                    _ = try await client.sendText(text, thread: id, offlineId: OfflineThreadingId.next())
                }
            } catch {
                failures += 1
                app.report(error)
            }
        }
        sending = false
        if failures < selected.count {
            app.show(failures == 0 ? "Sent" : "Sent to \(selected.count - failures) of \(selected.count)")
            close()
        }
    }

    private func close() { app.sharing = nil }
}
