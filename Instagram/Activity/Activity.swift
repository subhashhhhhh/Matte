import SwiftUI

/// One notification: who did what, when, and the post it's about.
nonisolated struct ActivityItem: Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var text: String
    /// Character ranges of usernames in `text` (shown bold).
    var names: [Range<Int>]
    var profile: User?
    var date: Date?
    var thumbnail: URL?
    /// The post it's about (pk), when there is one.
    var mediaPk: String?
    var isNew: Bool
}

extension IGClient {
    /// The activity inbox (likes, comments, follows, mentions), as instagram.com's heart shows it.
    func activity() async throws -> (items: [ActivityItem], unseen: Int) {
        let json = try await rest(.get, "/api/v1/news/inbox/")
        func parse(_ s: JSON, isNew: Bool) -> ActivityItem? {
            let a = s["args"]
            guard let text = a["text"].string ?? a["rich_text"].string else { return nil }
            let id = s["pk"].string ?? UUID().uuidString
            var profile: User?
            if let pid = Parser.idString(a["profile_id"]) {
                profile = User(id: pid, username: a["profile_name"].string ?? "", fullName: "",
                               avatar: a["profile_image"].string.flatMap(URL.init(string:)))
            }
            let names: [Range<Int>] = a["links"].array.compactMap { l in
                guard l["type"].string == "user", let start = l["start"].int, let end = l["end"].int, end > start else { return nil }
                return start..<end
            }
            let media = a["media"][0]
            let mediaPk = media["id"].string.flatMap { $0.split(separator: "_").first.map(String.init) }
            return ActivityItem(id: id, kind: s["notif_name"].string ?? "", text: text, names: names, profile: profile,
                                date: a["timestamp"].double.map { Date(timeIntervalSince1970: $0) },
                                thumbnail: media["image"].string.flatMap(URL.init(string:)),
                                mediaPk: mediaPk, isNew: isNew)
        }
        let fresh = json["new_stories"].array.compactMap { parse($0, isNew: true) }
        let old = json["old_stories"].array.compactMap { parse($0, isNew: false) }
        return (fresh + old, fresh.count)
    }

    /// Tells Instagram the activity was seen (clears the heart's dot), as the website does on open.
    func markActivitySeen() async throws {
        _ = try await rest(.post, "/api/v1/news/inbox_seen/", form: formTokens())
    }
}

@Observable
final class ActivityModel {
    private(set) var items: [ActivityItem] = []
    private(set) var unseen = 0
    private(set) var isLoading = false
    var isOpen = false {
        didSet { if isOpen { Task { await openPanel() } } }
    }
    /// A post opened from a notification.
    var opened: MediaDetailModel?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    #if DEBUG
    static var debugNeverMarkSeen = false
    #endif

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await client.activity()
            items = r.items
            unseen = r.unseen
        } catch {
            app?.report(error)
        }
    }

    private func openPanel() async {
        await refresh()
        guard unseen > 0 else { return }
        #if DEBUG
        if Self.debugNeverMarkSeen { return }
        #endif
        try? await client.markActivitySeen()
        unseen = 0
    }

    func open(_ item: ActivityItem) {
        if let pk = item.mediaPk {
            opened = MediaDetailModel.cached(pk: pk, client: client)
        } else if let user = item.profile {
            isOpen = false
            app?.openProfile(user)
        }
    }
}

/// The notifications panel: slides in from the right over the page.
struct ActivityPanel: View {
    let model: ActivityModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.system(size: 17, weight: .bold))
                Spacer()
                if model.isLoading { Spinner(size: 13) }
                ChromeButton("Close", symbol: "xmark") { model.isOpen = false }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let fresh = model.items.filter(\.isNew)
                    let old = model.items.filter { !$0.isNew }
                    if !fresh.isEmpty { section("New", fresh) }
                    if !old.isEmpty { section("Earlier", old) }
                    if model.items.isEmpty, !model.isLoading {
                        Text("Nothing yet").font(.system(size: 13)).foregroundStyle(.secondary).padding(30)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        .shadow(color: .black.opacity(0.25), radius: 24, x: -6)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ActivityItem]) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
        ForEach(items) { ActivityRow(item: $0, model: model) }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    let model: ActivityModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: item.profile?.avatar, size: 40).opensProfile(item.profile)
            (styledText + Text(item.date.map { "  " + $0.shortAge } ?? "").foregroundColor(.secondary))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let thumb = item.thumbnail {
                RemoteImage(url: thumb, contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.open(item) }
    }

    /// The text with usernames in bold (Instagram marks them by character range).
    private var styledText: Text {
        var out = AttributedString(item.text)
        let chars = Array(item.text.utf16)
        for r in item.names where r.upperBound <= chars.count {
            let start = String.Index(utf16Offset: r.lowerBound, in: item.text)
            let end = String.Index(utf16Offset: r.upperBound, in: item.text)
            if let a = AttributedString.Index(start, within: out), let b = AttributedString.Index(end, within: out) {
                out[a..<b].font = .system(size: 13, weight: .semibold)
            }
        }
        return Text(out)
    }
}
