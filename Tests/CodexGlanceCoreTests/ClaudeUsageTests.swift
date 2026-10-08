import XCTest
@testable import CodexGlanceCore

final class ClaudeUsageTests: XCTestCase {
    private let usageJSON = """
    {
      "five_hour": {"utilization": 23.0, "resets_at": "2027-01-15T10:59:59.943648+00:00"},
      "seven_day": {"utilization": 41.4, "resets_at": "2027-01-18T03:59:59.943679+00:00"},
      "seven_day_oauth_apps": null,
      "seven_day_opus": {"utilization": 12, "resets_at": null},
      "seven_day_sonnet": {"utilization": 5.5, "resets_at": "2027-01-18T03:59:59Z"},
      "iguana_necktie": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 120, "utilization": 2.4}
    }
    """

    func testMapperDecodesAccountWindowsAndModelBuckets() throws {
        let snapshot = try ClaudeUsageMapper.snapshot(
            usageData: Data(usageJSON.utf8),
            identity: AccountIdentity(email: "user@example.com", plan: "max"),
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(snapshot.current?.windowMinutes, 300)
        XCTAssertEqual(snapshot.current?.roundedUsedPercent, 23)
        XCTAssertEqual(snapshot.current?.resetsAt, try date("2027-01-15T10:59:59Z"))
        XCTAssertEqual(snapshot.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.weekly?.roundedUsedPercent, 41)
        XCTAssertEqual(snapshot.additionalLimits.map(\.name), ["Opus", "Sonnet"])
        XCTAssertEqual(snapshot.additionalLimits.first?.primary?.windowMinutes, 10_080)
        XCTAssertNil(snapshot.additionalLimits.first?.primary?.resetsAt)
        XCTAssertEqual(snapshot.identity, AccountIdentity(email: "user@example.com", plan: "max"))
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 10))

        let display = UsageDisplayFormatter.display(for: snapshot, now: try date("2027-01-15T08:59:59Z"))
        XCTAssertEqual(display.accountLine, "Account: user@example.com")
        XCTAssertEqual(display.usageLines.first, "5h: 77% remaining, resets in 2h 0m")
        XCTAssertEqual(display.additionalLimitLines.first, "Opus · wk: 88% remaining")
    }

    func testMapperPrefersLimitsListWithModelScopedWeeklyLimits() throws {
        let json = """
        {
          "five_hour": {"utilization": 3, "resets_at": "2026-10-08T11:00:00.357160+00:00"},
          "seven_day": {"utilization": 0, "resets_at": "2026-10-13T20:00:00.357181+00:00"},
          "seven_day_opus": null,
          "iguana_necktie": {"utilization": 0, "limit_dollars": 250, "resets_at": "2026-11-05T07:59:00+00:00"},
          "limits": [
            {"group": "session", "kind": "session", "percent": 3, "is_active": true,
             "resets_at": "2026-10-08T11:00:00.357160+00:00", "scope": null, "severity": "normal"},
            {"group": "weekly", "kind": "weekly_all", "percent": 0, "is_active": false,
             "resets_at": "2026-10-13T20:00:00.357181+00:00", "scope": null, "severity": "normal"},
            {"group": "weekly", "kind": "weekly_scoped", "percent": 40, "is_active": false,
             "resets_at": "2026-10-13T20:00:00+00:00",
             "scope": {"model": {"display_name": "Fable", "id": null}, "surface": null}, "severity": "normal"},
            {"group": "weekly", "kind": "weekly_unknown", "is_active": false}
          ]
        }
        """

        let snapshot = try ClaudeUsageMapper.snapshot(usageData: Data(json.utf8), identity: nil)

        XCTAssertEqual(snapshot.current, RateWindow(usedPercent: 3, windowMinutes: 300, resetsAt: try date("2026-10-08T11:00:00Z")))
        XCTAssertEqual(snapshot.weekly, RateWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: try date("2026-10-13T20:00:00Z")))
        XCTAssertEqual(snapshot.additionalLimits, [RateLimitBucket(
            id: "weekly_scoped-2",
            name: "Fable",
            primary: RateWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: try date("2026-10-13T20:00:00Z")),
            secondary: nil
        )])

        let display = UsageDisplayFormatter.display(for: snapshot, now: try date("2026-10-08T10:00:00Z"))
        XCTAssertEqual(display.additionalLimitLines, ["Fable · wk: 60% remaining, resets in 5d 10h"])

        let emptyLimits = try ClaudeUsageMapper.snapshot(
            usageData: Data(#"{"limits": [], "five_hour": {"utilization": 7}}"#.utf8),
            identity: nil
        )
        XCTAssertEqual(emptyLimits.current?.roundedUsedPercent, 7)
    }

    func testMapperKeepsUnknownDurationsAndRejectsPayloadWithoutWindows() throws {
        let snapshot = try ClaudeUsageMapper.snapshot(
            usageData: Data(#"{"thirty_day": {"utilization": 9}, "seven_day": {"utilization": 50}, "five_hour": {"utilization": 1}}"#.utf8),
            identity: AccountIdentity(email: nil, plan: nil)
        )

        XCTAssertEqual(snapshot.current?.windowMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.additionalLimits.map(\.name), ["All models"])
        XCTAssertEqual(snapshot.additionalLimits.first.flatMap(\.primary).map { UsageDisplayFormatter.windowLabel(for: $0) }, "30d")
        XCTAssertNil(snapshot.identity)

        for payload in [#"{}"#, #"{"extra_usage": {"utilization": 2}}"#, #"[]"#] {
            XCTAssertThrowsError(try ClaudeUsageMapper.snapshot(usageData: Data(payload.utf8), identity: nil)) { error in
                guard case ClaudeUsageError.invalidResponse = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testCredentialsPreferKeychainAndFallBackToConfigFile() throws {
        let keychain = Data(#"{"claudeAiOauth": {"accessToken": "keychain-token", "expiresAt": 1800000000000, "subscriptionType": "max"}}"#.utf8)
        let file = Data(#"{"claudeAiOauth": {"accessToken": "file-token", "expiresAt": 1800000000}}"#.utf8)
        let environment = ["HOME": "/Users/test"]
        var requestedPaths: [String] = []

        let fromKeychain = try ClaudeCredentialsLoader.load(
            environment: environment,
            readKeychain: { $0 == "Claude Code-credentials" ? keychain : nil },
            readFile: { _ in file }
        )
        XCTAssertEqual(fromKeychain, ClaudeCredentials(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            subscriptionType: "max"
        ))

        let fromFile = try ClaudeCredentialsLoader.load(
            environment: environment,
            readKeychain: { _ in Data("not json".utf8) },
            readFile: { requestedPaths.append($0); return file }
        )
        XCTAssertEqual(fromFile.accessToken, "file-token")
        XCTAssertEqual(fromFile.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(requestedPaths, ["/Users/test/.claude/.credentials.json"])

        XCTAssertThrowsError(try ClaudeCredentialsLoader.load(
            environment: environment,
            readKeychain: { _ in nil },
            readFile: { _ in Data(#"{"claudeAiOauth": {"accessToken": " "}}"#.utf8) }
        )) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .credentialsNotFound)
        }
    }

    func testLocalPathsHonorClaudeConfigDirectory() {
        XCTAssertEqual(ClaudeCredentialsLoader.credentialsPath(environment: ["HOME": "/Users/test"]), "/Users/test/.claude/.credentials.json")
        XCTAssertEqual(ClaudeCredentialsLoader.profilePath(environment: ["HOME": "/Users/test"]), "/Users/test/.claude.json")
        XCTAssertEqual(ClaudeCredentialsLoader.credentialsPath(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"]), "/tmp/claude/.credentials.json")
        XCTAssertEqual(ClaudeCredentialsLoader.profilePath(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"]), "/tmp/claude/.claude.json")
        XCTAssertEqual(
            ClaudeCredentialsLoader.parseAccountEmail(Data(#"{"projects": {}, "oauthAccount": {"emailAddress": " user@example.com "}}"#.utf8)),
            "user@example.com"
        )
        XCTAssertNil(ClaudeCredentialsLoader.parseAccountEmail(Data(#"{"projects": {}}"#.utf8)))
    }

    func testFetcherSendsOAuthRequestAndKeepsLastReadingWhenThrottled() throws {
        var statusCode = 200
        var requests: [URLRequest] = []
        let fetcher = makeFetcher(FakeCredentialStore()) { request in
            requests.append(request)
            return (Data(self.usageJSON.utf8), statusCode)
        }

        let first = try fetcher.fetch()
        XCTAssertEqual(requests.first?.url, ClaudeUsageFetcher.usageURL)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(first.identity, AccountIdentity(email: "user@example.com", plan: "pro"))

        statusCode = 429
        XCTAssertEqual(try fetcher.fetch(), first)

        // Without a refresh token, a rejected token means signing in again.
        for (status, expected) in [(401, ClaudeUsageError.unauthorized), (403, .unauthorized), (500, .httpStatus(500))] {
            statusCode = status
            XCTAssertThrowsError(try fetcher.fetch()) { error in
                XCTAssertEqual(error as? ClaudeUsageError, expected)
            }
        }

        let throttledFromStart = makeFetcher(FakeCredentialStore()) { _ in (Data(), 429) }
        XCTAssertThrowsError(try throttledFromStart.fetch()) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .rateLimited)
        }
    }

    func testExpiredTokenIsRefreshedSavedAndUsed() throws {
        let store = FakeCredentialStore(expiresAt: Date(timeIntervalSince1970: 99), refreshToken: "refresh-1")
        var requests: [URLRequest] = []
        let fetcher = makeFetcher(store) { request in
            requests.append(request)
            if request.url == ClaudeUsageFetcher.tokenURL {
                return (Data(self.tokenJSON.utf8), 200)
            }
            return (Data(self.usageJSON.utf8), 200)
        }

        _ = try fetcher.fetch()

        XCTAssertEqual(requests.map(\.url), [ClaudeUsageFetcher.tokenURL, ClaudeUsageFetcher.usageURL])
        let refresh = try XCTUnwrap(requests.first)
        XCTAssertEqual(refresh.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(refresh.httpBody)) as? [String: String])
        XCTAssertEqual(body, [
            "grant_type": "refresh_token",
            "refresh_token": "refresh-1",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:inference user:profile"
        ])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
        XCTAssertEqual(store.saved, [ClaudeRefreshedTokens(
            accessToken: "new-token",
            refreshToken: "refresh-2",
            expiresAt: Date(timeIntervalSince1970: 100 + 28_800),
            scopes: ["user:inference", "user:profile"]
        )])
        XCTAssertEqual(store.lockCount, 1)
    }

    func testRevokedTokenIsRefreshedOnceAfterUnauthorizedResponse() throws {
        let store = FakeCredentialStore(refreshToken: "refresh-1")
        var tokenRequests = 0
        let fetcher = makeFetcher(store) { request in
            if request.url == ClaudeUsageFetcher.tokenURL {
                tokenRequests += 1
                return (Data(self.tokenJSON.utf8), 200)
            }
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token"
            return (Data(self.usageJSON.utf8), authorized ? 200 : 401)
        }

        XCTAssertEqual(try fetcher.fetch().current?.roundedUsedPercent, 23)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(store.credentials.accessToken, "new-token")
    }

    func testRefreshReusesSignInThatClaudeCodeRefreshedMeanwhile() throws {
        let store = FakeCredentialStore(expiresAt: Date(timeIntervalSince1970: 99), refreshToken: "refresh-1")
        store.onLock = {
            store.credentials = ClaudeCredentials(
                accessToken: "from-claude-code",
                refreshToken: "refresh-9",
                expiresAt: Date(timeIntervalSince1970: 10_000),
                subscriptionType: "pro"
            )
        }
        var requests: [URLRequest] = []
        let fetcher = makeFetcher(store) { request in
            requests.append(request)
            return (Data(self.usageJSON.utf8), 200)
        }

        _ = try fetcher.fetch()

        XCTAssertEqual(requests.map(\.url), [ClaudeUsageFetcher.usageURL])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer from-claude-code")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testRejectedOrMissingRefreshTokenAsksToSignInAgain() {
        let rejected = FakeCredentialStore(expiresAt: Date(timeIntervalSince1970: 99), refreshToken: "refresh-1")
        let rejectingFetcher = makeFetcher(rejected) { request in
            (Data(#"{"error": "invalid_grant"}"#.utf8), request.url == ClaudeUsageFetcher.tokenURL ? 400 : 200)
        }
        XCTAssertThrowsError(try rejectingFetcher.fetch()) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .unauthorized)
        }
        XCTAssertTrue(rejected.saved.isEmpty)

        var didSend = false
        let withoutRefreshToken = makeFetcher(FakeCredentialStore(expiresAt: Date(timeIntervalSince1970: 99))) { _ in
            didSend = true
            return (Data(), 200)
        }
        XCTAssertThrowsError(try withoutRefreshToken.fetch()) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .unauthorized)
        }
        XCTAssertFalse(didSend)
    }

    func testRefreshedSignInThatCouldNotBeSavedStaysUsable() throws {
        let store = FakeCredentialStore(expiresAt: Date(timeIntervalSince1970: 99), refreshToken: "refresh-1")
        store.saveError = ClaudeUsageError.saveFailed
        var tokenRequests = 0
        let fetcher = makeFetcher(store) { request in
            if request.url == ClaudeUsageFetcher.tokenURL {
                tokenRequests += 1
                return (Data(self.tokenJSON.utf8), 200)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            return (Data(self.usageJSON.utf8), 200)
        }

        XCTAssertThrowsError(try fetcher.fetch()) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .saveFailed)
        }
        XCTAssertEqual(try fetcher.fetch().current?.roundedUsedPercent, 23)
        XCTAssertEqual(tokenRequests, 1)
    }

    func testMergedCredentialsReplaceOnlyTokenFields() throws {
        let stored = Data(#"{"mcpOAuth": {"server": {"accessToken": "mcp"}}, "claudeAiOauth": {"accessToken": "old", "refreshToken": "refresh-1", "expiresAt": 1, "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}"#.utf8)
        let tokens = ClaudeRefreshedTokens(
            accessToken: "new",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000.5),
            scopes: nil
        )

        let merged = try XCTUnwrap(ClaudeCredentialsLoader.mergedCredentialsData(stored, with: tokens))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual((root["mcpOAuth"] as? [String: [String: String]])?["server"]?["accessToken"], "mcp")
        XCTAssertEqual(oauth["accessToken"] as? String, "new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-1")
        XCTAssertEqual((oauth["expiresAt"] as? NSNumber)?.int64Value, 1_800_000_000_500)
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertEqual(ClaudeCredentialsLoader.parse(merged)?.refreshToken, "refresh-1")
    }

    func testKeychainAccountIsReadFromItemAttributes() {
        let attributes = """
        keychain: "/Users/test/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="test"
            "svce"<blob>="Claude Code-credentials"
        """
        XCTAssertEqual(ClaudeKeychain.parseAccount(fromAttributes: attributes), "test")
        XCTAssertNil(ClaudeKeychain.parseAccount(fromAttributes: #""acct"<blob>=<NULL>"#))
    }

    func testDirectoryLockWaitsForItsOwnerAndReclaimsStaleLocks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".oauth_refresh.lock").path

        let held = try ClaudeDirectoryLock.acquire(at: path, staleAfter: 10)
        XCTAssertThrowsError(try ClaudeDirectoryLock.acquire(at: path, staleAfter: 10, timeout: 0.3)) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .refreshInProgress)
        }
        held.release()
        try ClaudeDirectoryLock.acquire(at: path, staleAfter: 10).release()

        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: path)
        let reclaimed = try ClaudeDirectoryLock.acquire(at: path, staleAfter: 10, timeout: 0.3)
        reclaimed.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private let tokenJSON = #"{"token_type": "Bearer", "access_token": "new-token", "refresh_token": "refresh-2", "expires_in": 28800, "scope": "user:inference user:profile"}"#

    private func makeFetcher(
        _ store: FakeCredentialStore,
        send: @escaping ClaudeUsageFetcher.HTTPSend
    ) -> ClaudeUsageFetcher {
        ClaudeUsageFetcher(
            store: store,
            loadAccountEmail: { "user@example.com" },
            send: send,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private final class FakeCredentialStore: ClaudeCredentialStore {
    var credentials: ClaudeCredentials
    var saved: [ClaudeRefreshedTokens] = []
    var saveError: Error?
    var onLock: (() -> Void)?
    private(set) var lockCount = 0

    init(expiresAt: Date? = Date(timeIntervalSince1970: 1_000), refreshToken: String? = nil) {
        credentials = ClaudeCredentials(
            accessToken: "token",
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: ["user:inference", "user:profile"],
            subscriptionType: "pro"
        )
    }

    func load() throws -> ClaudeCredentials {
        credentials
    }

    func withRefreshLock<T>(_ body: () throws -> T) throws -> T {
        lockCount += 1
        onLock?()
        return try body()
    }

    func save(_ tokens: ClaudeRefreshedTokens) throws {
        if let saveError {
            throw saveError
        }
        saved.append(tokens)
        credentials = credentials.applying(tokens)
    }
}
