import XCTest
@testable import CodexGlanceCore

final class CodexGlanceCoreTests: XCTestCase {
    func testMenuTitleUsesCurrentAndWeeklyRemainingPercentages() {
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(usedPercent: 68.2, windowMinutes: 300, resetsAt: nil),
            weekly: RateWindow(usedPercent: 40.6, windowMinutes: 10_080, resetsAt: nil),
            credits: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(CodexUsageDisplayFormatter.menuTitle(for: snapshot), "5h 32%\nwk 59%")
    }

    func testMenuTitleMatchesCompactExamples() {
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(usedPercent: 32, windowMinutes: 300, resetsAt: nil),
            weekly: RateWindow(usedPercent: 59, windowMinutes: 10_080, resetsAt: nil),
            credits: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(CodexUsageDisplayFormatter.menuTitle(for: snapshot), "5h 68%\nwk 41%")
    }

    func testMenuTitleCanHideWeeklyUsage() {
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(usedPercent: 32, windowMinutes: 300, resetsAt: nil),
            weekly: RateWindow(usedPercent: 59, windowMinutes: 10_080, resetsAt: nil),
            credits: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(CodexUsageDisplayFormatter.menuTitle(for: snapshot, includeWeekly: false), "5h 68%")
    }

    func testMenuTitleIncludesCompactResetTimes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(8_640)),
            weekly: RateWindow(usedPercent: 59, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(111_600)),
            credits: nil,
            identity: nil,
            updatedAt: now
        )

        XCTAssertEqual(
            CodexUsageDisplayFormatter.menuTitle(for: snapshot, includeWeekly: true, now: now),
            "5h 88% 2h24m\nwk 41% 1d7h"
        )
    }

    func testMenuLinesIncludeResetTimeFractionRemaining() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(9_000)),
            weekly: nil,
            credits: nil,
            identity: nil,
            updatedAt: now
        )

        let line = CodexUsageDisplayFormatter.menuLines(for: snapshot, includeWeekly: false, now: now)[0]

        XCTAssertEqual(line.resetTimeFractionRemaining ?? -1, 0.5, accuracy: 0.001)
    }

    func testMapperDecodesRPCShape() throws {
        let limits: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 12.3,
                    "windowDurationMins": 300,
                    "resetsAt": 1_800_000_000
                ],
                "secondary": [
                    "usedPercent": 45.6,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_800_010_000
                ],
                "credits": [
                    "hasCredits": true,
                    "unlimited": false,
                    "balance": "4992"
                ],
                "planType": "pro"
            ]
        ]
        let account: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "email": "user@example.com",
                "planType": "pro"
            ],
            "requiresOpenaiAuth": false
        ]

        let snapshot = try CodexUsageMapper.snapshot(
            limitsResult: limits,
            accountResult: account,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(snapshot.current?.roundedUsedPercent, 12)
        XCTAssertEqual(snapshot.weekly?.roundedUsedPercent, 46)
        XCTAssertEqual(snapshot.credits?.balance, "4992")
        XCTAssertEqual(snapshot.identity?.email, "user@example.com")
        XCTAssertEqual(snapshot.identity?.plan, "pro")
    }

    func testMapperRecoversUsageFromRPCErrorBody() throws {
        let message = """
        request failed body={"email":"user@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":37,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":58,"limit_window_seconds":604800,"reset_at":1800010000}},"credits":{"balance":42}}
        """

        let snapshot = try XCTUnwrap(CodexUsageMapper.snapshotFromErrorMessage(message))

        XCTAssertEqual(snapshot.current?.roundedUsedPercent, 37)
        XCTAssertEqual(snapshot.weekly?.roundedUsedPercent, 58)
        XCTAssertEqual(snapshot.current?.windowMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.credits?.balance, "42.0")
        XCTAssertEqual(snapshot.identity?.email, "user@example.com")
    }
}
