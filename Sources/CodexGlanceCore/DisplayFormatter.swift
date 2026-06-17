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
            return placeholderLines(includeWeekly: includeWeekly)
        }

        var lines = [
            CodexUsageMenuLine(
                label: "5h",
                remainingPercent: remainingPercentage(snapshot.current),
                resetText: compactResetDescription(for: snapshot.current, now: now)
            )
        ]

        if includeWeekly {
            lines.append(
                CodexUsageMenuLine(
                    label: "wk",
                    remainingPercent: remainingPercentage(snapshot.weekly),
                    resetText: compactResetDescription(for: snapshot.weekly, now: now)
                )
            )
        }

        return lines
    }

    public static func display(for snapshot: CodexUsageSnapshot, includeWeekly: Bool = true, now: Date = Date()) -> CodexUsageDisplay {
        CodexUsageDisplay(
            title: menuTitle(for: snapshot, includeWeekly: includeWeekly, now: now),
            currentLine: "5h: \(windowDescription(snapshot.current, now: now))",
            weeklyLine: "wk: \(windowDescription(snapshot.weekly, now: now))",
            creditsLine: creditsDescription(snapshot.credits),
            accountLine: accountDescription(snapshot.identity),
            updatedLine: "Updated: \(timeFormatter.string(from: snapshot.updatedAt))"
        )
    }

    public static func errorTitle(includeWeekly: Bool = true) -> String {
        includeWeekly ? "5h --%\nwk --%" : "5h --%"
    }

    private static func placeholderLines(includeWeekly: Bool) -> [CodexUsageMenuLine] {
        var lines = [
            CodexUsageMenuLine(label: "5h", remainingPercent: nil, resetText: nil)
        ]

        if includeWeekly {
            lines.append(CodexUsageMenuLine(label: "wk", remainingPercent: nil, resetText: nil))
        }

        return lines
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

    private static func compactResetDescription(for window: RateWindow?, now: Date) -> String? {
        guard let resetsAt = window?.resetsAt else {
            return nil
        }

        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 {
            return "now"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "\(days)d\(hours)h"
        }

        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }

        return "\(minutes)m"
    }

    private static func resetDescription(for window: RateWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return ""
        }

        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 {
            return ", reset due now"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
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
