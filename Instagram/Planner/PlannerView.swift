import SwiftUI

/// The Planner page (Manager mode): a month of scheduled posts, and the upcoming ones in a list.
/// Clicking a day's "+" opens the create sheet set to that day.
struct PlannerView: View {
    @Environment(AppModel.self) private var app
    let model: PlannerModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let problem = model.problem, model.posts.isEmpty {
                    Text(problem)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
                }
                MonthGrid(model: model)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Rectangle().fill(Theme.hairline).frame(width: 1)
            UpcomingList(model: model)
                .frame(width: 300)
        }
        .task { await model.loadIfNeeded() }
        .overlay {
            if let post = model.confirmingCancel {
                ConfirmDialog(title: "Cancel scheduled post?",
                              message: "It won't be published. This can't be undone.",
                              action: "Cancel Post",
                              busy: model.cancelling.contains(post.id),
                              confirm: { Task { await model.cancel(post) } },
                              cancel: { model.confirmingCancel = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.confirmingCancel == nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 22, weight: .bold))
            Spacer()
            if model.loading { Spinner(size: 14) }
            Button("Today") { model.goToToday() }.buttonStyle(.secondaryPill)
            ChromeButton("Previous month", symbol: "chevron.left") { model.step(months: -1) }
            ChromeButton("Next month", symbol: "chevron.right") { model.step(months: 1) }
            ChromeButton("Refresh", symbol: "arrow.clockwise", shortcut: "r") { Task { await model.reload() } }
            Button("Schedule Post") { model.schedule(on: .now) }
                .buttonStyle(.prominentCompact)
        }
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let model: PlannerModel
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let days = model.gridDays
        let rows = max(days.count / 7, 1)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i].uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            GeometryReader { g in
                let height = (g.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows)
                VStack(spacing: 6) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(days[(r * 7)..<min(r * 7 + 7, days.count)], id: \.self) { day in
                                DayCell(model: model, day: day, inMonth: cal.isDate(day, equalTo: model.month, toGranularity: .month))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(height, 60))
                            }
                        }
                    }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let s = cal.shortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }
}

private struct DayCell: View {
    let model: PlannerModel
    let day: Date
    let inMonth: Bool
    @State private var hovering = false
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let posts = model.posts(on: day)
        let today = cal.isDateInToday(day)
        let past = cal.startOfDay(for: day) < cal.startOfDay(for: .now)
        let canAdd = !past && cal.startOfDay(for: day) <= Date.now.addingTimeInterval(IGClient.scheduleWindow.max)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(today ? AnyShapeStyle(Theme.background) : AnyShapeStyle(.primary))
                    .frame(minWidth: 22, minHeight: 22)
                    .background { if today { Circle().fill(.primary) } }
                Spacer()
                if hovering, canAdd {
                    Button { model.schedule(on: day) } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20).background(Circle().fill(Theme.selected))
                    }
                    .buttonStyle(.pressable)
                    .help("Schedule a post on this day")
                }
            }
            ForEach(posts.prefix(3)) { post in
                ScheduledChip(post: post)
            }
            if posts.count > 3 {
                Text("+\(posts.count - 3) more").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : Theme.panel.opacity(inMonth ? 1 : 0.4)))
        .opacity(inMonth ? (past ? 0.55 : 1) : 0.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ScheduledChip: View {
    let post: ScheduledPost

    var body: some View {
        HStack(spacing: 5) {
            RemoteImage(url: post.thumbnail)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(post.publishAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.trailing, 6)
        .padding(2)
        .background(Capsule().fill(Theme.selected))
        .help(post.caption.isEmpty ? post.kind.title : post.caption)
    }
}

// MARK: - Upcoming

private struct UpcomingList: View {
    let model: PlannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upcoming")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 56)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.upcoming.isEmpty {
                VStack(spacing: 8) {
                    IGGlyph(icon: .calendar, size: 28).foregroundStyle(.tertiary)
                    Text(model.loaded ? "Nothing scheduled" : "Loading…")
                        .font(.system(size: 13, weight: .medium))
                    Text("Schedule a photo from here, or turn on Schedule in the create sheet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.upcoming) { post in UpcomingRow(model: model, post: post) }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct UpcomingRow: View {
    let model: PlannerModel
    let post: ScheduledPost
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: post.thumbnail)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if post.kind != .photo {
                        Image(systemName: post.kind.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .shadow(radius: 1).padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(post.publishAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(post.caption.isEmpty ? post.kind.title : post.caption)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if hovering || model.cancelling.contains(post.id) {
                Button { model.confirmingCancel = post } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24).background(Circle().fill(Theme.selected))
                }
                .buttonStyle(.pressable)
                .help("Cancel this scheduled post")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
    }
}

extension ScheduledPost.Kind {
    var title: String {
        switch self {
        case .photo: "Photo"
        case .carousel: "Carousel"
        case .reel: "Reel"
        case .video: "Video"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .carousel: "square.on.square"
        case .reel: "play.fill"
        case .video: "video.fill"
        }
    }
}
