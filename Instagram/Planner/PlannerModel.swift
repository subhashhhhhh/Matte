import SwiftUI
import OSLog

/// The Planner (Manager mode): the current account's scheduled posts on a month calendar.
/// Instagram keeps and publishes them; this lists, adds (through the create sheet) and cancels.
@Observable
final class PlannerModel {
    private(set) var posts: [ScheduledPost] = []
    private(set) var loading = false
    private(set) var loaded = false
    /// Why the list couldn't load (a personal account can't schedule, for one).
    private(set) var problem: String?
    /// The first day of the month on screen.
    var month: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    /// The scheduled post whose "Cancel?" is being confirmed.
    var confirmingCancel: ScheduledPost?
    private(set) var cancelling: Set<String> = []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "Planner")
    private static let cacheKey = "scheduled"

    init(app: AppModel?, client: IGClient) {
        self.app = app
        self.client = client
        if let cached = app?.cache?.load([ScheduledPost].self, Self.cacheKey, maxAge: 2 * 86_400) {
            posts = cached.value.filter { $0.publishAt > .now }
        }
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await client.scheduledPosts()
            posts = fresh
            problem = nil
            loaded = true
            app?.cache?.save(Array(fresh.prefix(200)), Self.cacheKey)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case IGError.signedOut = error { app?.report(error); return }
            log.error("Scheduled posts failed: \(error.localizedDescription, privacy: .public)")
            loaded = true
            problem = "Couldn't load scheduled posts. Scheduling needs a professional (business or creator) account. \(error.localizedDescription)"
        }
    }

    /// Scheduled posts on `day`, in time order.
    func posts(on day: Date) -> [ScheduledPost] {
        let cal = Calendar.current
        return posts.filter { cal.isDate($0.publishAt, inSameDayAs: day) }
    }

    var upcoming: [ScheduledPost] { posts.filter { $0.publishAt > .now.addingTimeInterval(-60) } }

    func step(months n: Int) {
        if let m = Calendar.current.date(byAdding: .month, value: n, to: month) { month = m }
    }

    func goToToday() {
        month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    }

    /// The grid's days: whole weeks covering the month (days of other months included).
    var gridDays: [Date] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: interval.start) else { return [] }
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let weeks = Int((Double(lead + daysInMonth) / 7).rounded(.up))
        return (0..<(weeks * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Opens the create sheet set to publish on `day` (at 9:00, or the soonest time allowed).
    func schedule(on day: Date) {
        guard let app else { return }
        let cal = Calendar.current
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        app.openCreate(target: .post)
        app.creating?.scheduleAt = SchedulePicker.clamp(nine)
    }

    func cancel(_ post: ScheduledPost) async {
        guard !cancelling.contains(post.id) else { return }
        cancelling.insert(post.id)
        defer { cancelling.remove(post.id) }
        do {
            try await client.cancelScheduled(id: post.id)
            posts.removeAll { $0.id == post.id }
            confirmingCancel = nil
            app?.cache?.remove(Self.cacheKey)
            app?.show("Scheduled post cancelled")
        } catch {
            confirmingCancel = nil
            app?.report(error)
        }
    }

    /// A post was just scheduled from the create sheet.
    func didSchedule() {
        Task { await reload() }
    }
}
