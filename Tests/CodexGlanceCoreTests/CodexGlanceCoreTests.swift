import XCTest
@testable import CodexGlanceCore

final class CodexGlanceCoreTests: XCTestCase {
    func testExecutableLocatorSupportsChatGPTAndCodexApps() {
        let chatGPTPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let codexPath = "/Applications/Codex.app/Contents/Resources/codex"
        let environment = ["PATH": "/usr/bin"]

        XCTAssertEqual(
            CodexExecutableLocator.find(environment: environment) { $0 == chatGPTPath },
            chatGPTPath
        )
        XCTAssertEqual(
            CodexExecutableLocator.find(environment: environment) { $0 == codexPath },
            codexPath
        )
    }

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

    func testPrimaryWeeklyWindowUsesWeeklyLabelAndOmitsMissingSecondary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexUsageSnapshot(
            current: RateWindow(
                usedPercent: 2,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(6 * 86_400 + 12 * 3_600)
            ),
            weekly: nil,
            credits: nil,
            identity: nil,
            updatedAt: now
        )

        XCTAssertEqual(
            CodexUsageDisplayFormatter.menuTitle(for: snapshot, includeWeekly: true, now: now),
            "wk 98% 6d"
        )
        XCTAssertEqual(
            CodexUsageDisplayFormatter.display(for: snapshot, now: now).usageLines,
            ["wk: 98% remaining, resets in 6d 12h"]
        )
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

    func testWeeklyResetTimeUsesCoarserPrecisionWhenFarAway() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cases: [(TimeInterval, String)] = [
            (6 * 86_400 + 3_600 + 15 * 60, "6d"),
            (86_400 + 7 * 3_600 + 15 * 60, "1d7h"),
            (12 * 3_600 + 42 * 60, "12h"),
            (2 * 3_600 + 24 * 60, "2h24m")
        ]

        for (seconds, resetText) in cases {
            let snapshot = CodexUsageSnapshot(
                current: nil,
                weekly: RateWindow(
                    usedPercent: 59,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(seconds)
                ),
                credits: nil,
                identity: nil,
                updatedAt: now
            )

            let line = CodexUsageDisplayFormatter.menuLines(for: snapshot, includeWeekly: true, now: now)[1]
            XCTAssertEqual(line.resetText, resetText)
        }
    }

    func testDisplayUsesDaysForWeeklyResetDescription() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexUsageSnapshot(
            current: nil,
            weekly: RateWindow(
                usedPercent: 59,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(86_400 + 7 * 3_600 + 15 * 60)
            ),
            credits: nil,
            identity: nil,
            updatedAt: now
        )

        let display = CodexUsageDisplayFormatter.display(for: snapshot, includeWeekly: true, now: now)

        XCTAssertEqual(display.usageLines, ["wk: 41% remaining, resets in 1d 7h"])
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

    func testMapperDecodesRateLimitsUpdatedPayload() throws {
        let rateLimits: [String: Any] = [
            "primary": [
                "used_percent": 21,
                "limit_window_seconds": 18_000,
                "reset_at": 1_800_000_000
            ],
            "secondary": [
                "used_percent": 63.5,
                "limit_window_seconds": 604_800,
                "reset_at": 1_800_010_000
            ],
            "credits": [
                "hasCredits": true,
                "unlimited": false,
                "balance": "128"
            ],
            "plan_type": "pro"
        ]
        let account: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "email": "user@example.com",
                "plan_type": "pro"
            ]
        ]

        let snapshot = try CodexUsageMapper.snapshot(
            rateLimits: rateLimits,
            accountResult: account,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(snapshot.current?.roundedUsedPercent, 21)
        XCTAssertEqual(snapshot.current?.windowMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.roundedUsedPercent, 64)
        XCTAssertEqual(snapshot.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.identity?.email, "user@example.com")
        XCTAssertEqual(snapshot.identity?.plan, "pro")
    }

    func testMapperDecodesMultiBucketLimitsAndResetCredits() throws {
        let limits: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 2,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_800_000_000
                ],
                "planType": "prolite"
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 2,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_800_000_000
                    ]
                ],
                "codex_bengalfox": [
                    "limitId": "codex_bengalfox",
                    "limitName": "GPT-5.3-Codex-Spark",
                    "primary": [
                        "usedPercent": 0,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_800_010_000
                    ]
                ]
            ],
            "rateLimitResetCredits": [
                "availableCount": 3
            ]
        ]

        let snapshot = try CodexUsageMapper.snapshot(
            limitsResult: limits,
            accountResult: nil,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(snapshot.current?.windowMinutes, 10_080)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.additionalLimits.count, 1)
        XCTAssertEqual(snapshot.additionalLimits.first?.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(snapshot.additionalLimits.first?.primary?.remainingPercent, 100)
        XCTAssertEqual(snapshot.resetCreditsAvailable, 3)

        let display = CodexUsageDisplayFormatter.display(for: snapshot, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(display.resetCreditsLine, "Reset credits: 3")
        XCTAssertEqual(display.additionalLimitLines.count, 1)
        XCTAssertTrue(display.additionalLimitLines[0].hasPrefix("GPT-5.3-Codex-Spark · wk: 100% remaining"))
    }

    func testMapperPrefersRateLimitsPlanForUsageTier() throws {
        let limits: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 12,
                    "windowDurationMins": 300,
                    "resetsAt": 1_800_000_000
                ],
                "planType": "pro"
            ]
        ]
        let account: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "email": "user@example.com",
                "planType": "plus"
            ]
        ]

        let snapshot = try CodexUsageMapper.snapshot(
            limitsResult: limits,
            accountResult: account,
            now: Date(timeIntervalSince1970: 10)
        )

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
