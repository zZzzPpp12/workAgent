import Foundation

struct HistoryFilter: Equatable {
    var interval: DateInterval
    var source: String?
    var project: String?

    func includes(_ run: HistoricalRun) -> Bool {
        (source == nil || source == run.source) && (project == nil || project == run.project)
    }
}

struct HistoryDay: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var completed = 0
    var failed = 0
    var stopped = 0
}

struct HistorySummary: Equatable {
    var completed = 0
    var failed = 0
    var stopped = 0
    var partial = 0
    var waits = 0
    var waitSeconds: TimeInterval = 0
    var calendarWaitSeconds: TimeInterval = 0
    var matchedWaits = 0
    var deferredSeconds: TimeInterval = 0
    var nonDeferredSeconds: TimeInterval = 0
    var days: [HistoryDay] = []
}

enum HistoryStatistics {
    static func groupedByWeek(_ days: [HistoryDay], calendar: Calendar = .current) -> [HistoryDay] {
        var grouped: [Date: HistoryDay] = [:]
        for day in days {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: day.day)?.start else { continue }
            var week = grouped[start] ?? HistoryDay(day: start)
            week.completed += day.completed
            week.failed += day.failed
            week.stopped += day.stopped
            grouped[start] = week
        }
        return grouped.values.sorted { $0.day < $1.day }
    }
    /// 不同会话的等待区间求并集，避免把并行等待重复加到自然时间中。
    static func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, next.end))
            } else {
                total += current.duration
                current = next
            }
        }
        return total + current.duration
    }

    static func clipped(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        let start = max(interval.start, bounds.start)
        let end = min(interval.end, bounds.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    static func summarize(runs: [HistoricalRun], attentions: [AttentionRecord], filter: HistoryFilter,
                          calendar: Calendar = .current) -> HistorySummary {
        var summary = HistorySummary()
        var intervals: [DateInterval] = []
        let rows = runs.filter(filter.includes)
        let attentionByRequest = Dictionary(grouping: attentions.compactMap { item -> (String, AttentionRecord)? in
            guard let request = item.requestKey else { return nil }
            return (item.taskID + "\u{0}" + item.runID + "\u{0}" + request, item)
        }, by: { $0.0 })
        var byDay: [Date: HistoryDay] = [:]
        for run in rows {
            if let end = run.snapshot.endedAt, filter.interval.contains(end), end < filter.interval.end {
                let day = calendar.startOfDay(for: end)
                var daily = byDay[day] ?? HistoryDay(day: day)
                switch run.status {
                case .completed: summary.completed += 1; daily.completed += 1
                case .failed: summary.failed += 1; daily.failed += 1
                case .stopped: summary.stopped += 1; daily.stopped += 1
                default: break
                }
                byDay[day] = daily
            }
            let representative = run.snapshot.endedAt ?? run.snapshot.startedAt ?? run.observedAt
            if (run.snapshot.isPartial || !run.snapshot.hasExplicitStart || run.status == .unknown),
               filter.interval.contains(representative), representative < filter.interval.end {
                summary.partial += 1
            }
            for step in run.snapshot.steps where step.kind == .interaction && step.status == .returned {
                guard let start = step.startedAt, let end = step.endedAt, end > start,
                      let interval = clipped(DateInterval(start: start, end: end), to: filter.interval) else { continue }
                summary.waits += 1
                summary.waitSeconds += interval.duration
                intervals.append(interval)

                // 只有明确关联到同一请求、且从创建时即完整记录的延后历史才参与精确统计。
                let request = step.id.hasPrefix("tool:") ? String(step.id.dropFirst(5)) : step.id
                guard let sourceRunID = run.snapshot.runID,
                      let matches = attentionByRequest[run.taskID + "\u{0}" + sourceRunID + "\u{0}" + request], matches.count == 1,
                      let attention = matches.first?.1, attention.snoozeHistoryComplete == true, let snoozes = attention.snoozeHistory,
                      !snoozes.contains(where: { $0.invalidClock || $0.endedAt == nil }) else { continue }
                let deferred = snoozes.compactMap { entry -> DateInterval? in
                    guard let end = entry.endedAt, end > entry.startedAt else { return nil }
                    return clipped(DateInterval(start: entry.startedAt, end: end), to: interval)
                }
                let deferredDuration = unionDuration(deferred)
                summary.matchedWaits += 1
                summary.deferredSeconds += deferredDuration
                summary.nonDeferredSeconds += max(0, interval.duration - deferredDuration)
            }
        }
        summary.calendarWaitSeconds = unionDuration(intervals)
        summary.days = byDay.values.sorted { $0.day < $1.day }
        return summary
    }
}
