import SwiftUI

/// "Forward to…": pick one or more chats for a message (the "Send to…" sheet's pattern).
struct ForwardSheet: View {
    let conversation: ConversationModel
    let message: DMMessage
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selected: [String] = []
    @State private var sending = false
    @FocusState private var searchFocused: Bool

    private var threads: [DMThread] {
        let all = (app.inbox?.threads ?? []).filter { $0.id != conversation.thread.id }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { t in t.title.lowercased().contains(q) || t.users.contains { $0.username.lowercased().contains(q) } }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Forward to").font(.system(size: 15, weight: .bold))
                        Text(DMNotifier.preview(message)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.pressable)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    IGGlyph(icon: .search, size: 14).foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
                .padding(12)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(threads) { thread in
                            let isSelected = selected.contains(thread.id)
                            HStack(spacing: 12) {
                                ThreadAvatar(thread: thread, size: 44)
                                Text(thread.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
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
                            Text("No other chats").font(.system(size: 13)).foregroundStyle(.secondary).padding(30)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { Task { await send() } } label: {
                    Text(sending ? "Sending…" : "Forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.link.opacity(selected.isEmpty || sending ? 0.4 : 1)))
                }
                .buttonStyle(.pressable)
                .disabled(selected.isEmpty || sending)
                .padding(12)
            }
            .frame(width: 420, height: 540)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.3), radius: 30)
        }
        .onAppear { searchFocused = true }
    }

    private func send() async {
        guard !selected.isEmpty, !sending else { return }
        sending = true
        let failures = await conversation.forward(message, to: selected)
        sending = false
        if failures < selected.count {
            app.show(failures == 0 ? "Forwarded" : "Forwarded to \(selected.count - failures) of \(selected.count)")
            close()
        }
    }

    private func close() { conversation.forwarding = nil }
}
