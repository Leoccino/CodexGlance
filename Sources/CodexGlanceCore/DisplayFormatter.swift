import Foundation

public enum CodexUsageDisplayFormatter {
    public static func menuTitle(
        for snapshot: CodexUsageSnapshot?,
        includeWeekly: Bool = true,
        now: Date = Date()
    ) -> String {
        menuLines(for: snapshot, includeWeekly: includeWeekly, now: now)
            .map(titleLine)
            .joined(separator: "\n")
    }

    public static func menuLines(
        for snapshot: CodexUsageSnapshot?,
        includeWeekly: Bool = true,
        now: Date = Date()
    ) -> [CodexUsageMenuLine] {
        guard let snapshot else {
            return placeholderLines()
        }

        var lines: [CodexUsageMenuLine] = []
        if let current = snapshot.current {
            lines.append(
                CodexUsageMenuLine(
                    label: windowLabel(for: current, fallback: "use"),
                    remainingPercent: remainingPercentage(snapshot.current),
                    resetText: compactResetDescription(for: snapshot.current, now: now),
                    resetTimeFractionRemaining: resetTimeFractionRemaining(for: snapshot.current, now: now)
                )
            )
        }

        if includeWeekly, let weekly = snapshot.weekly {
            lines.append(
                CodexUsageMenuLine(
                    label: windowLabel(for: weekly, fallback: "more"),
                    remainingPercent: remainingPercentage(snapshot.weekly),
                    resetText: compactResetDescription(for: snapshot.weekly, now: now),
                    resetTimeFractionRemaining: resetTimeFractionRemaining(for: snapshot.weekly, now: now)
                )
            )
        }

        return lines.isEmpty ? placeholderLines() : lines
    }

    public static func display(for snapshot: CodexUsageSnapshot, includeWeekly: Bool = true, now: Date = Date()) -> CodexUsageDisplay {
        CodexUsageDisplay(
            title: menuTitle(for: snapshot, includeWeekly: includeWeekly, now: now),
            usageLines: usageDetailLines(for: snapshot, now: now),
            additionalLimitLines: additionalLimitLines(for: snapshot.additionalLimits, now: now),
            resetCreditsLine: resetCreditsDescription(snapshot.resetCreditsAvailable),
            creditsLine: creditsDescription(snapshot.credits),
            accountLine: accountDescription(snapshot.identity),
            updatedLine: "Updated: \(timeFormatter.string(from: snapshot.updatedAt))"
        )
    }

    public static func errorTitle(includeWeekly _: Bool = true) -> String {
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

    private static func placeholderLines() -> [CodexUsageMenuLine] {
        [CodexUsageMenuLine(label: "use", remainingPercent: nil, resetText: nil)]
    }

    private static func titleLine(_ line: CodexUsageMenuLine) -> String {
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

    private static func usageDetailLines(for snapshot: CodexUsageSnapshot, now: Date) -> [String] {
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
