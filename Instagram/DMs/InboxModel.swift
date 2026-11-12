import SwiftUI
import OSLog

/// The DM inbox and the open conversation.
@Observable
final class InboxModel {
    private(set) var threads: [DMThread] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    var selectedId: String? {
        didSet { if selectedId != oldValue { openSelected() } }
    }
    private(set) var conversation: ConversationModel?
    var unreadCount: Int { threads.filter(\.isUnread).count }

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private(set) var seqId: String?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored let client: IGClient
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var loadedOnce = false
    /// True while the real-time socket is subscribed (polling pauses meanwhile).
    private(set) var isLive = false
    /// The real-time DM connection (docs/dm-protocol.md §5), once the inbox gave a seq id.
    @ObservationIgnored private(set) var realtime: DMRealtime?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    /// After the gateway refused the session (and a normal request showed it's fine): when to try again.
    @ObservationIgnored private var realtimeRetryAt = Date.distantPast
    @ObservationIgnored private var inboxRefresh: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "DMs")

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    var selected: DMThread? { threads.first { $0.id == selectedId } }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await refresh()
        startRealtime()
        startPolling()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let box = try await client.inbox()
            merge(box.threads)
            cursor = box.cursor
            hasMore = box.hasMore
            seqId = box.seqId
            loadFailed = false
        } catch {
            loadFailed = threads.isEmpty
            app?.report(error)
        }
    }

    func loadMore() async {
        guard hasMore, let cursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.olderThreads(cursor: cursor)
            merge(page.threads)
            self.cursor = page.cursor
            hasMore = page.hasMore
        } catch {
            app?.report(error)
        }
    }

    /// Updates threads in place (new activity moves a thread to the top).
    private func merge(_ fresh: [DMThread]) {
        var byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in fresh {
            var t = t
            // The open thread is read as it arrives.
            if t.id == selectedId { t.isUnread = false }
            byId[t.id] = t
        }
        threads = byId.values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// The open thread's newest state (after sending, or a poll).
    func update(_ thread: DMThread) { merge([thread]) }

    private func openSelected() {
        conversation?.stop()
        conversation = nil
        guard let thread = selected else { return }
        conversation = ConversationModel(inbox: self, thread: thread, client: client)
        if let i = threads.firstIndex(where: { $0.id == thread.id }) { threads[i].isUnread = false }
    }

    func report(_ error: Error) { app?.report(error) }

    // MARK: Real-time

    private func startRealtime() {
        guard realtime == nil, Date.now >= realtimeRetryAt, let seq = seqId.flatMap(Int64.init) else { return }
        let rt = DMRealtime(client: client, seqId: seq)
        realtime = rt
        realtimeTask = Task { [weak self] in
            await rt.start()
            for await event in rt.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func stopRealtime() {
        let rt = realtime
        realtime = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        isLive = false
        Task { await rt?.stop() }
    }

    private func handle(_ event: DMRealtimeEvent) async {
        switch event {
        case .connected:
            isLive = true
        case .disconnected:
            isLive = false
        case .unauthorized:
            // Check with an ordinary request: a dead session signs out through `report`;
            // otherwise keep polling and try the socket again later.
            // (Outside this event loop's task, which stopping cancels.)
            stopRealtime()
            realtimeRetryAt = .now.addingTimeInterval(600)
            Task { [weak self] in await self?.refresh() }
        case .resnapshot:
            // Our cursor is too old: take a new snapshot and resume from it.
            let old = seqId
            await refresh()
            if let seq = seqId.flatMap(Int64.init), seqId != old {
                await realtime?.restart(seqId: seq)
            } else {
                // No new snapshot (offline?): poll, and the poll loop reconnects later.
                stopRealtime()
            }
        case .message(let id, let message):
            conversation(id)?.receive(message)
            bumpRow(id, with: message)
        case .messageDeleted(let id, let messageId):
            conversation(id)?.remove(messageId)
            refreshInboxSoon()
        case .messageEdited(let id, _, _), .reaction(let id, _, _, _):
            conversation(id)?.refreshSoon()
        case .readReceipt(let id, let who, let at):
            conversation(id)?.applyReadReceipt(who, at: at)
            if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].readUpTo[who] = at }
        case .markedRead(let id):
            if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].isUnread = false }
        case .typing(let longId, _, let typing):
            if let c = conversation, c.thread.longId == longId { c.setPeerTyping(typing) }
        case .threadChanged(let id):
            conversation(id)?.refreshSoon()
            refreshInboxSoon()
        }
    }

    private func conversation(_ threadId: String) -> ConversationModel? {
        conversation?.thread.id == threadId ? conversation : nil
    }

    /// A new message moves its thread to the top with a new snippet (no request); an unknown
    /// thread means fetching the inbox again.
    private func bumpRow(_ id: String, with message: DMMessage) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { refreshInboxSoon(); return }
        var row = threads[i]
        if let last = row.lastActivity, message.sentAt < last { return }
        row.lastActivity = message.sentAt
        row.snippet = message.previewText
        row.lastSenderIsViewer = message.senderId == row.viewerMessagingId
        if !row.lastSenderIsViewer { row.isUnread = true }
        merge([row])
    }

    /// Fetches the inbox's first page once a burst of changes has settled.
    private func refreshInboxSoon() {
        inboxRefresh?.cancel()
        inboxRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Fallback polling (only while the socket is down)

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if self.isLive { continue }
                await self.conversation?.poll()
                await self.refresh()
                self.startRealtime()
            }
        }
    }

    func stop() {
        poller?.cancel()
        inboxRefresh?.cancel()
        stopRealtime()
        conversation?.stop()
    }
}

/// One conversation: messages oldest first (for display), older pages on demand, sending.
@Observable
final class ConversationModel {
    private(set) var thread: DMThread
    private(set) var messages: [DMMessage] = []
    private(set) var isLoading = false
    private(set) var loadingOlder = false
    private(set) var hasOlder = false
    var draft = ""
    var replyingTo: DMMessage?
    /// Bumped when new messages arrive at the bottom (the view scrolls to them).
    private(set) var newestToken = 0
    /// Someone else in the thread is typing (from the real-time socket; clears itself after 6 s).
    private(set) var peerTyping = false

    @ObservationIgnored private var typingExpiry: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var sentTyping: (on: Bool, at: Date)?

    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private weak var inbox: InboxModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var markedReadUpTo: String?

    init(inbox: InboxModel, thread: DMThread, client: IGClient) {
        self.inbox = inbox
        self.thread = thread
        self.client = client
        Task { await load() }
    }

    var viewerId: String? { thread.viewerMessagingId }

    func user(for messagingId: String) -> User? {
        thread.users.first { $0.messagingId == messagingId }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await client.thread(thread.id)
            if let t = r.thread { thread = merged(t) }
            messages = r.messages.items.reversed()
            olderCursor = r.messages.cursor
            hasOlder = r.messages.hasMore
            newestToken += 1
            await markRead()
        } catch {
            inbox?.report(error)
        }
    }

    /// Keeps what the inbox knows that the detail query leaves out.
    private func merged(_ t: DMThread) -> DMThread {
        var t = t
        if t.viewerMessagingId == nil { t.viewerMessagingId = thread.viewerMessagingId }
        if t.users.isEmpty { t.users = thread.users }
        t.isMuted = thread.isMuted
        t.isPinned = thread.isPinned
        t.isUnread = false
        return t
    }

    func loadOlder() async {
        guard hasOlder, let olderCursor, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await client.olderMessages(thread: thread.id, cursor: olderCursor)
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: page.items.reversed().filter { !known.contains($0.id) }, at: 0)
            self.olderCursor = page.cursor
            hasOlder = page.hasMore
        } catch {
            inbox?.report(error)
        }
    }

    /// Fetches the newest messages and adds any we don't have.
    func poll() async {
        guard !isLoading else { return }
        guard let r = try? await client.thread(thread.id) else { return }
        if let t = r.thread { thread = merged(t) }
        let fresh = r.messages.items.reversed()
        var changed = false
        for m in fresh {
            if let i = messages.firstIndex(where: { $0.id == m.id || ($0.offlineId != nil && $0.offlineId == m.offlineId) }) {
                if messages[i] != m { messages[i] = m; changed = true }
            } else {
                messages.append(m)
                changed = true
            }
        }
        if changed {
            messages.sort { $0.sentAt < $1.sentAt }
            newestToken += 1
            await markRead()
        }
    }

    // MARK: Real-time updates

    /// A message from the socket: replaces our pending copy (same offline id) or is added.
    func receive(_ message: DMMessage) {
        if let i = messages.firstIndex(where: { $0.id == message.id || ($0.offlineId != nil && $0.offlineId == message.offlineId) }) {
            var m = message
            if m.replyTo == nil { m.replyTo = messages[i].replyTo }
            if messages[i] != m { messages[i] = m }
        } else {
            messages.append(message)
            if messages.count > 1, messages[messages.count - 2].sentAt > message.sentAt { messages.sort { $0.sentAt < $1.sentAt } }
            newestToken += 1
        }
        if message.senderId != viewerId {
            setPeerTyping(false)
            Task { await markRead() }
        }
    }

    func remove(_ messageId: String) {
        messages.removeAll { $0.id == messageId }
    }

    func applyReadReceipt(_ participant: String, at: Date) {
        if (thread.readUpTo[participant] ?? .distantPast) < at { thread.readUpTo[participant] = at }
    }

    func setPeerTyping(_ typing: Bool) {
        typingExpiry?.cancel()
        if peerTyping != typing { peerTyping = typing }
        guard typing else { return }
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.peerTyping = false
        }
    }

    /// Refetches the newest messages once a burst of changes (edits, reactions) has settled.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.poll()
        }
    }

    /// Tells the thread we're typing (`true`) or stopped. Meant to be called as the draft
    /// changes: repeats of the same state within 5 s aren't sent again.
    func sendTyping(_ typing: Bool) async {
        if let last = sentTyping, last.on == typing, !typing || Date.now.timeIntervalSince(last.at) < 5 { return }
        guard let realtime = inbox?.realtime else { return }
        sentTyping = (typing, .now)
        try? await realtime.setTyping(typing, threadId: thread.id)
    }

    // MARK: Actions

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let viewerId else { return }
        draft = ""
        let reply = replyingTo
        replyingTo = nil
        let otid = OfflineThreadingId.next()
        var local = DMMessage(id: "local-\(otid)", senderId: viewerId, sentAt: .now, body: .text(text))
        local.pending = true
        local.offlineId = otid
        if let reply { local.replyTo = .init(id: reply.id, senderId: reply.senderId, text: reply.previewText) }
        messages.append(local)
        newestToken += 1
        do {
            let id = try await client.sendText(text, thread: thread.id, replyTo: reply?.id, offlineId: otid)
            if let i = messages.firstIndex(where: { $0.offlineId == otid && $0.pending }) {
                messages[i].pending = false
                if let id { messages[i].id = id }
            }
            thread.snippet = text
            thread.lastActivity = .now
            thread.lastSenderIsViewer = true
            inbox?.update(thread)
        } catch {
            if let i = messages.firstIndex(where: { $0.offlineId == otid }) {
                messages[i].pending = false
                messages[i].failed = true
            }
            inbox?.report(error)
        }
    }

    /// Removes a failed message and puts its text back in the box.
    func retry(_ message: DMMessage) {
        guard case .text(let t) = message.body else { return }
        messages.removeAll { $0.id == message.id }
        draft = t
    }

    func toggleReaction(_ emoji: String, on message: DMMessage) async {
        guard let viewerId, let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let mine = messages[i].reactions.first { $0.senderId == viewerId }
        let removing = mine?.emoji == emoji
        // One reaction per person: replace ours.
        messages[i].reactions.removeAll { $0.senderId == viewerId }
        if !removing { messages[i].reactions.append(DMReaction(emoji: emoji, senderId: viewerId)) }
        do {
            try await client.react(removing ? nil : emoji, previous: mine?.emoji, to: message.id, thread: thread.id)
        } catch {
            if let j = messages.firstIndex(where: { $0.id == message.id }) { messages[j].reactions = message.reactions }
            inbox?.report(error)
        }
    }

    func unsend(_ message: DMMessage) async {
        guard let longId = thread.longId else { return }
        let backup = messages
        messages.removeAll { $0.id == message.id }
        do {
            try await client.unsend(message.id, longThreadId: longId)
        } catch {
            messages = backup
            inbox?.report(error)
        }
    }

    /// Tells Instagram we've read up to the newest message from the other side.
    private func markRead() async {
        guard let longId = thread.longId,
              let newest = messages.last(where: { $0.senderId != viewerId && !$0.pending }),
              newest.id != markedReadUpTo else { return }
        if let mine = viewerId.flatMap({ thread.readUpTo[$0] }), mine >= newest.sentAt { markedReadUpTo = newest.id; return }
        markedReadUpTo = newest.id
        try? await client.markRead(longThreadId: longId, message: newest)
    }

    func stop() {
        typingExpiry?.cancel()
        pendingRefresh?.cancel()
        if sentTyping?.on == true, let realtime = inbox?.realtime {
            let id = thread.id
            Task { try? await realtime.setTyping(false, threadId: id) }
        }
    }
}
