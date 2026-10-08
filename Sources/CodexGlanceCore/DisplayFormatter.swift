import Foundation

public enum UsageDisplayFormatter {
    public static func menuTitle(
        for snapshot: UsageSnapshot?,
        windows: MenuBarWindows = .both,
        now: Date = Date()
    ) -> String {
        menuLines(for: snapshot, windows: windows, now: now)
            .map(titleLine)
            .joined(separator: "\n")
    }

    public static func menuLines(
        for snapshot: UsageSnapshot?,
        windows: MenuBarWindows = .both,
        now: Date = Date()
    ) -> [UsageMenuLine] {
        guard let snapshot else {
            return placeholderLines()
        }

        let current = snapshot.current.map { menuLine(for: $0, fallback: "use", now: now) }
        let weekly = snapshot.weekly.map { menuLine(for: $0, fallback: "more", now: now) }
        let lines: [UsageMenuLine]
        switch windows {
        // A product without the chosen window shows the one it has.
        case .current:
            lines = [current ?? weekly].compactMap { $0 }
        case .weekly:
            lines = [weekly ?? current].compactMap { $0 }
        case .both:
            lines = [current, weekly].compactMap { $0 }
        }

        return lines.isEmpty ? placeholderLines() : lines
    }

    private static func menuLine(for window: RateWindow, fallback: String, now: Date) -> UsageMenuLine {
        UsageMenuLine(
            label: windowLabel(for: window, fallback: fallback),
            remainingPercent: remainingPercentage(window),
            resetText: compactResetDescription(for: window, now: now),
            resetTimeFractionRemaining: resetTimeFractionRemaining(for: window, now: now)
        )
    }

    public static func display(for snapshot: UsageSnapshot, windows: MenuBarWindows = .both, now: Date = Date()) -> UsageDisplay {
        UsageDisplay(
            title: menuTitle(for: snapshot, windows: windows, now: now),
            usageLines: usageDetailLines(for: snapshot, now: now),
            additionalLimitLines: additionalLimitLines(for: snapshot.additionalLimits, now: now),
            resetCreditsLine: resetCreditsDescription(snapshot.resetCreditsAvailable),
            creditsLine: creditsDescription(snapshot.credits),
            accountLine: accountDescription(snapshot.identity),
            updatedLine: "Updated: \(timeFormatter.string(from: snapshot.updatedAt))"
        )
    }

    public static func errorTitle() -> String {
        "use --%"
    }

    public static func windowLabel(for window: RateWindow, fallback: String = "use") -> String {
        guard let minutes = window.windowMinutes, minutes > 0 else {
            return fallback
        }

        if minutes == 10_080 {
            return "wk"
        }
        if minutes % 10_080 == 0 {
            return "\(minutes / 10_080)wk"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func placeholderLines() -> [UsageMenuLine] {
        [UsageMenuLine(label: "use", remainingPercent: nil, resetText: nil)]
    }

    private static func titleLine(_ line: UsageMenuLine) -> String {
        let percentage = line.remainingPercent.map { "\($0)%" } ?? "--%"
        guard let resetText = line.resetText, !resetText.isEmpty else {
            return "\(line.label) \(percentage)"
        }

        return "\(line.label) \(percentage) \(resetText)"
    }

    private static func remainingPercentage(_ window: RateWindow?) -> Int? {
        guard let window else {
            return nil
        }

        return Int(window.remainingPercent.rounded())
    }

    private static func windowDescription(_ window: RateWindow?, now: Date) -> String {
        guard let window else {
            return "unavailable"
        }

        let reset = resetDescription(for: window, now: now)
        return "\(Int(window.remainingPercent.rounded()))% remaining\(reset)"
    }

    private static func usageDetailLines(for snapshot: UsageSnapshot, now: Date) -> [String] {
        var lines: [String] = []
        if let current = snapshot.current {
            lines.append("\(windowLabel(for: current)): \(windowDescription(current, now: now))")
        }
        if let weekly = snapshot.weekly {
            lines.append("\(windowLabel(for: weekly, fallback: "more")): \(windowDescription(weekly, now: now))")
        }
        return lines
    }

    private static func additionalLimitLines(for buckets: [RateLimitBucket], now: Date) -> [String] {
        buckets.flatMap { bucket in
            let name = bucket.name ?? bucket.id
            var lines: [String] = []
            if let primary = bucket.primary {
                lines.append("\(name) · \(windowLabel(for: primary)): \(windowDescription(primary, now: now))")
            }
            if let secondary = bucket.secondary {
                lines.append("\(name) · \(windowLabel(for: secondary, fallback: "more")): \(windowDescription(secondary, now: now))")
            }
            return lines
        }
    }

    private static func compactResetDescription(for window: RateWindow?, now: Date) -> String? {
        guard let window, let resetsAt = window.resetsAt else {
            return nil
        }

        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 {
            return "now"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if (window.windowMinutes ?? 0) > 24 * 60 {
            return compactLongWindowReset(days: days, hours: hours, minutes: minutes)
        }

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }

        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }

        return "\(minutes)m"
    }

    private static func compactLongWindowReset(days: Int, hours: Int, minutes: Int) -> String {
        if days > 1 {
            return "\(days)d"
        }

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }

        if hours >= 3 {
            return "\(hours)h"
        }

        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }

        return "\(minutes)m"
    }

    private static func resetTimeFractionRemaining(for window: RateWindow?, now: Date) -> Double? {
        guard
            let window,
            let resetsAt = window.resetsAt,
            let windowMinutes = window.windowMinutes,
            windowMinutes > 0
        else {
            return nil
        }

        let seconds = max(0, resetsAt.timeIntervalSince(now))
        let totalSeconds = Double(windowMinutes * 60)
        return min(1, max(0, seconds / totalSeconds))
    }

    private static func resetDescription(for window: RateWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return ""
        }

        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 {
            return ", reset due now"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return hours > 0 ? ", resets in \(days)d \(hours)h" : ", resets in \(days)d"
        }

        if hours > 0 {
            return ", resets in \(hours)h \(minutes)m"
        }

        return ", resets in \(minutes)m"
    }

    private static func creditsDescription(_ credits: Credits?) -> String? {
        guard let credits, credits.hasCredits else {
            return nil
        }

        if credits.unlimited {
            return "Credits: unlimited"
        }

        return "Credits: \(credits.balance ?? "0")"
    }

    private static func resetCreditsDescription(_ available: Int?) -> String? {
        guard let available, available > 0 else {
            return nil
        }

        return "Reset credits: \(available)"
    }

    private static func accountDescription(_ identity: AccountIdentity?) -> String? {
        guard let identity else {
            return nil
        }

        switch (clean(identity.email), clean(identity.plan)) {
        case let (email?, _):
            return "Account: \(email)"
        case let (nil, plan?):
            return "Plan: \(plan)"
        case (nil, nil):
            return nil
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
