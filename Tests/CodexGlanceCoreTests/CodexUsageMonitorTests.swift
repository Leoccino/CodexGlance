import XCTest
@testable import CodexGlanceCore

final class CodexUsageMonitorTests: XCTestCase {
    private static let usage: [String: Any] = [
        "rateLimits": [
            "primary": ["usedPercent": 27, "windowDurationMins": 300, "resetsAt": 1_800_000_000]
        ]
    ]
    private static let noUsage: [String: Any] = ["rateLimits": [String: Any]()]

    func testStaleSessionThatReportsNoUsageIsReplacedImmediately() throws {
        let sessions = FakeSessions([Self.usage, Self.noUsage, Self.usage])
        let monitor = CodexUsageMonitor(makeClient: sessions.make)

        XCTAssertEqual(try monitor.fetch().current?.roundedUsedPercent, 27)
        XCTAssertEqual(try monitor.fetch().current?.roundedUsedPercent, 27)
        XCTAssertEqual(sessions.created.count, 2)
        XCTAssertTrue(sessions.created[0].isShutdown)
        XCTAssertFalse(sessions.created[1].isShutdown)
    }

    func testFreshSessionWithoutUsageReportsAnErrorInsteadOfRetrying() {
        let sessions = FakeSessions([Self.noUsage, Self.noUsage])
        let monitor = CodexUsageMonitor(makeClient: sessions.make)

        XCTAssertThrowsError(try monitor.fetch()) { error in
            XCTAssertEqual(error as? CodexRPCError, .noUsageData)
        }
        XCTAssertEqual(sessions.created.count, 1)
        XCTAssertTrue(sessions.created[0].isShutdown)
    }

    func testLongLivedSessionIsRecycled() throws {
        var now = Date(timeIntervalSince1970: 0)
        let sessions = FakeSessions([Self.usage, Self.usage, Self.usage])
        let monitor = CodexUsageMonitor(makeClient: sessions.make, now: { now })

        _ = try monitor.fetch()
        now += CodexUsageMonitor.maximumTransportAge - 1
        _ = try monitor.fetch()
        XCTAssertEqual(sessions.created.count, 1)

        now += 1
        _ = try monitor.fetch()
        XCTAssertEqual(sessions.created.count, 2)
        XCTAssertTrue(sessions.created[0].isShutdown)
    }
}

private final class FakeSessions {
    private var rateLimitResponses: [[String: Any]]
    private(set) var created: [FakeSession] = []

    init(_ rateLimitResponses: [[String: Any]]) {
        self.rateLimitResponses = rateLimitResponses
    }

    func make() throws -> CodexRPCSession {
        let session = FakeSession { [unowned self] in
            self.rateLimitResponses.removeFirst()
        }
        created.append(session)
        return session
    }
}

private final class FakeSession: CodexRPCSession {
    private let nextRateLimits: () -> [String: Any]
    private(set) var isShutdown = false

    init(nextRateLimits: @escaping () -> [String: Any]) {
        self.nextRateLimits = nextRateLimits
    }

    func initialize(timeout: TimeInterval) throws {}

    func call(method: String, params: [String: Any]?, timeout: TimeInterval) throws -> [String: Any] {
        guard method == "account/rateLimits/read" else {
            throw CodexRPCError.requestFailed("unsupported in test")
        }
        return nextRateLimits()
    }

    func notify(method: String, params: [String: Any]?) throws {}

    func shutdown() {
        isShutdown = true
    }

    func setNotificationHandler(_ handler: CodexRPCNotificationHandler?) {}

    func setDisconnectHandler(_ handler: CodexRPCDisconnectHandler?) {}
}
