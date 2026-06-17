import Foundation

public enum CodexUsageDisplayFormatter {
    public static func menuTitle(for snapshot: CodexUsageSnapshot?) -> String {
        guard let snapshot else {
            return "C-- W--"
        }

        return "C\(percentage(snapshot.current)) W\(percentage(snapshot.weekly))"
    }

    public static func display(for snapshot: CodexUsageSnapshot, now: Date = Date()) -> CodexUsageDisplay {
        CodexUsageDisplay(
            title: menuTitle(for: snapshot),
            currentLine: "Current: \(windowDescription(snapshot.current, now: now))",
            weeklyLine: "Weekly: \(windowDescription(snapshot.weekly, now: now))",
            creditsLine: creditsDescription(snapshot.credits),
            accountLine: accountDescription(snapshot.identity),
            updatedLine: "Updated: \(timeFormatter.string(from: snapshot.updatedAt))"
        )
    }

    public static func errorTitle() -> String {
        "C-- W--"
    }

    private static func percentage(_ window: RateWindow?) -> String {
        guard let window else {
            return "--"
        }

        return "\(Int(window.remainingPercent.rounded()))"
    }

    private static func windowDescription(_ window: RateWindow?, now: Date) -> String {
        guard let window else {
            return "unavailable"
        }

        let reset = resetDescription(for: window, now: now)
        return "\(Int(window.remainingPercent.rounded()))% remaining\(reset)"
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
        case let (email?, plan?):
            return "Account: \(email) (\(plan))"
        case let (email?, nil):
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
