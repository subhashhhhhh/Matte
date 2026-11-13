import SwiftUI

/// The Replies page (Manager mode): comments on your recent posts, newest first, filtered to the
/// ones waiting for an answer. Each one can be answered inline, liked or marked done.
struct RepliesView: View {
    let model: RepliesModel
    @State private var open: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .task {
            await model.loadIfNeeded()
            #if DEBUG
            // `-IGRepliesOpen YES`: open the reply box on the first comment (screenshots; nothing is sent).
            if UserDefaults.standard.bool(forKey: "IGRepliesOpen") { withAnimation(nil) { open = model.shown.first?.id } }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replies").font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            SegmentedTabs(tabs: RepliesModel.Filter.allCases.map { ($0, $0.title) },
                          selection: Binding(get: { model.filter }, set: { model.filter = $0 }))
                .frame(width: 260)
            if model.loading { Spinner(size: 14) }
            ChromeButton("Refresh", symbol: "arrow.clockwise", shortcut: "r") { Task { await model.refresh() } }
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
    }

    private var subtitle: String {
        if !model.loaded || model.problem != nil { return "Comments on your last \(RepliesModel.postLimit) posts" }
        let n = model.waitingCount
        let waiting = n == 0 ? "Nothing waiting" : "\(n) waiting for a reply"
        return waiting + " · last \(RepliesModel.postLimit) posts"
    }

    @ViewBuilder
    private var content: some View {
        if let problem = model.problem, model.items.isEmpty {
            EmptyState(symbol: "exclamationmark.bubble", title: "Couldn't load comments", message: problem,
                       actionTitle: "Try Again") { Task { await model.refresh() } }
        } else if model.shown.isEmpty {
            if model.loaded {
                EmptyState(symbol: "checkmark.bubble", title: model.filter == .needsReply ? "All caught up" : "No comments yet",
                           message: model.filter == .needsReply ? "Every comment on your recent posts has a reply from you." : "Comments on your recent posts show up here.")
            } else {
                VStack(spacing: 10) {
                    Spinner(size: 20)
                    Text("Reading comments on your recent posts…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.shown) { item in
                        ReplyRow(model: model, item: item, isOpen: open == item.id) {
                            withAnimation(Motion.pop) { open = open == item.id ? nil : item.id }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ReplyRow: View {
    @Environment(AppModel.self) private var app
    let model: RepliesModel
    let item: RepliesModel.Item
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(url: item.comment.user?.avatar, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.comment.user?.username ?? "someone").font(.system(size: 13, weight: .semibold))
                        if let date = item.comment.createdAt {
                            Text(date.formatted(.relative(presentation: .named)))
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        if item.answered {
                            Text("Replied").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Theme.selected))
                        }
                    }
                    Text(item.comment.text.isEmpty ? (item.comment.gif != nil ? "GIF" : "") : item.comment.text)
                        .font(.system(size: 13.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 14) {
                        Button(action: toggle) {
                            Text(isOpen ? "Close" : "Reply").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(.secondary)
                        if !item.answered {
                            Button { model.markDone(item) } label: {
                                Text("Mark done").font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.pressable)
                            .foregroundStyle(.secondary)
                            .help("Hide it from Needs reply without answering")
                        }
                        if item.comment.likeCount > 0 {
                            Text("\(item.comment.likeCount) like\(item.comment.likeCount == 1 ? "" : "s")")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        if item.comment.replyCount > 0 {
                            Text("\(item.comment.replyCount) repl\(item.comment.replyCount == 1 ? "y" : "ies")")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                Button { Task { await model.toggleLike(item) } } label: {
                    IGGlyph(icon: item.comment.liked ? .heartFilled : .heart, size: 14)
                        .foregroundStyle(item.comment.liked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.secondary))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(item.comment.liked ? "Unlike" : "Like")
                Button { app.openedMedia = item.post } label: {
                    RemoteImage(url: item.post.image(minWidth: 96))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.pressable)
                .help("Open the post")
            }
            if isOpen {
                ReplyComposer(model: model, item: item)
                    .padding(.leading, 46)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering || isOpen ? Theme.hover : Theme.panel))
        .onHover { hovering = $0 }
    }
}

private struct ReplyComposer: View {
    let model: RepliesModel
    let item: RepliesModel.Item
    @FocusState private var focused: Bool

    var body: some View {
        let text = model.draft(for: item)
        let sending = model.sending.contains(item.id)
        VStack(alignment: .leading, spacing: 8) {
            if let name = item.comment.user?.username {
                Text("Replying to @\(name)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Write a reply…", text: Binding(get: { model.draft(for: item) }, set: { model.drafts[item.id] = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { Task { await model.send(item) } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.panelStroke))
                Button {
                    model.save(reply: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    IGGlyph(icon: .save, size: 15).frame(width: 30, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.secondary)
                .help("Save as a reusable reply")
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    Task { await model.send(item) }
                } label: {
                    if sending { Spinner(size: 13).frame(width: 40) } else { Text("Post") }
                }
                .buttonStyle(.prominentCompact)
                .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.savedReplies.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.savedReplies, id: \.self) { saved in
                            Button { model.useSaved(saved, for: item); focused = true } label: {
                                Text(saved).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .frame(maxWidth: 220)
                                    .background(Capsule().fill(Theme.selected))
                            }
                            .buttonStyle(.pressable)
                            .contextMenu { Button("Remove Saved Reply") { model.removeSaved(saved) } }
                            .help(saved)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { focused = true }
    }
}
