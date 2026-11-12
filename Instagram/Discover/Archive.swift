import SwiftUI

/// Your story archive: a grid of days, each playing its stories in the story viewer.
@Observable
final class ArchiveModel {
    private(set) var days: [ArchiveDay] = []
    /// Stories per day id, loaded in batches as days come into view (the first one is the cover).
    private(set) var stories: [String: [Media]] = [:]
    private(set) var isLoading = false
    private(set) var failed = false
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.archiveDays(after: cursor)
            days += page.days.filter { d in !days.contains { $0.id == d.id } }
            cursor = page.next
            hasMore = page.next != nil
        } catch {
            failed = days.isEmpty
            app?.report(error)
        }
    }

    /// Loads this day's stories and the next few days' (the web app asks for several at once).
    func appeared(_ day: ArchiveDay) {
        guard let i = days.firstIndex(of: day) else { return }
        let batch = days[i..<min(days.count, i + 8)].map(\.id).filter { !requested.contains($0) }
        guard !batch.isEmpty else { return }
        requested.formUnion(batch)
        Task {
            do {
                let loaded = try await client.archiveReels(batch)
                for (id, items) in loaded { stories[id] = items }
            } catch {
                requested.subtract(batch)
            }
        }
        if i >= days.count - 4 { Task { await loadMore() } }
    }

    func play(_ day: ArchiveDay) {
        guard let app, let me = app.me, let items = stories[day.id], !items.isEmpty else { return }
        var reel = StoryReel(id: day.id, user: me, seen: true)
        reel.items = items
        app.openStories([reel], at: 0)
    }
}

struct ArchiveView: View {
    let model: ArchiveModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archive").font(.system(size: 22, weight: .bold))
                    Text("Only you can see your archived stories.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                    ForEach(model.days) { day in
                        ArchiveTile(day: day, cover: model.stories[day.id]?.first)
                            .onAppear { model.appeared(day) }
                            .onTapGesture { model.play(day) }
                    }
                }
                if model.isLoading { Spinner().frame(maxWidth: .infinity).padding(20) }
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .overlay {
            if model.days.isEmpty, !model.isLoading {
                EmptyState(symbol: "clock.arrow.circlepath", title: model.failed ? "Couldn't load your archive" : "No archived stories")
            }
        }
        .task { if model.days.isEmpty { await model.loadMore() } }
    }
}

private struct ArchiveTile: View {
    let day: ArchiveDay
    let cover: Media?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16, contentMode: .fit)
            .overlay {
                RemoteImage(url: cover?.image(minWidth: 320), contentMode: .fill)
                    .scaleEffect(hovering && !Motion.reduced ? 1.04 : 1)
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if let date = day.date {
                    VStack(spacing: 0) {
                        Text(date.formatted(.dateTime.day())).font(.system(size: 18, weight: .bold))
                        Text(date.formatted(.dateTime.month(.abbreviated))).font(.system(size: 11, weight: .semibold)).textCase(.uppercase)
                        if !Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
                            Text(date.formatted(.dateTime.year())).font(.system(size: 10, weight: .medium)).opacity(0.8)
                        }
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.92)))
                    .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if day.count > 1 {
                    Text("\(day.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(.black.opacity(0.5))).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.3), value: hovering)
    }
}
