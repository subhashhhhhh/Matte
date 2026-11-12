import SwiftUI

/// Picks when a post goes up: a month of days and a time, in the app's style (no system date
/// picker). Only times Instagram accepts (`IGClient.scheduleWindow`) can be picked.
struct SchedulePicker: View {
    @Binding var date: Date
    @State private var month: Date = .now

    private var cal: Calendar { Calendar.current }

    /// `date` moved into the window Instagram accepts, on a 5-minute mark.
    static func clamp(_ date: Date) -> Date {
        let lo = Date.now.addingTimeInterval(IGClient.scheduleWindow.min)
        let hi = Date.now.addingTimeInterval(IGClient.scheduleWindow.max)
        let d = min(max(date, lo), hi)
        let t = d.timeIntervalSinceReferenceDate
        let step: TimeInterval = 300
        var rounded = Date(timeIntervalSinceReferenceDate: (t / step).rounded(.up) * step)
        if rounded > hi { rounded = Date(timeIntervalSinceReferenceDate: (t / step).rounded(.down) * step) }
        return rounded
    }

    static func isAllowed(_ date: Date) -> Bool {
        let gap = date.timeIntervalSinceNow
        return gap >= IGClient.scheduleWindow.min - 60 && gap <= IGClient.scheduleWindow.max
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                stepButton("chevron.left", by: -1)
                stepButton("chevron.right", by: 1)
            }
            let symbols = orderedWeekdaySymbols
            HStack(spacing: 0) {
                ForEach(symbols.indices, id: \.self) { i in
                    Text(symbols[i]).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in dayCell(day) }
            }
            HStack(spacing: 8) {
                Text("Time").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                timeStepper(minutes: -60, symbol: "chevron.left.2", help: "An hour earlier")
                timeStepper(minutes: -5, symbol: "chevron.left", help: "5 minutes earlier")
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 78)
                timeStepper(minutes: 5, symbol: "chevron.right", help: "5 minutes later")
                timeStepper(minutes: 60, symbol: "chevron.right.2", help: "An hour later")
            }
        }
        .onAppear { month = cal.dateInterval(of: .month, for: date)?.start ?? date }
    }

    private var orderedWeekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private var days: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: interval.start) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let start = cal.date(byAdding: .day, value: -lead, to: interval.start) ?? interval.start
        let weeks = Int((Double(lead + count) / 7).rounded(.up))
        return (0..<(weeks * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let selected = cal.isDate(day, inSameDayAs: date)
        let target = moved(to: day)
        let clamped = Self.clamp(target)
        let allowed = cal.isDate(clamped, inSameDayAs: day) && Self.isAllowed(clamped)
        return Button {
            date = clamped
        } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 12, weight: selected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(selected ? AnyShapeStyle(Theme.background) : allowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    if selected { Circle().fill(.primary).frame(width: 28, height: 28) }
                    else if cal.isDateInToday(day) { Circle().strokeBorder(.primary.opacity(0.3)).frame(width: 28, height: 28) }
                }
                .opacity(inMonth ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!allowed)
    }

    /// `date`'s time of day on `day`.
    private func moved(to day: Date) -> Date {
        let parts = cal.dateComponents([.hour, .minute], from: date)
        return cal.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }

    private func stepButton(_ symbol: String, by n: Int) -> some View {
        Button {
            if let m = cal.date(byAdding: .month, value: n, to: month) { month = m }
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                .background(Circle().fill(Theme.panel)).contentShape(Circle())
        }
        .buttonStyle(.pressable)
    }

    private func timeStepper(minutes: Int, symbol: String, help: String) -> some View {
        let next = date.addingTimeInterval(TimeInterval(minutes * 60))
        return Button {
            date = Self.clamp(next)
            month = cal.dateInterval(of: .month, for: date)?.start ?? month
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26)
                .background(Circle().fill(Theme.panel)).contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .help(help)
        .disabled(!Self.isAllowed(next))
    }
}
