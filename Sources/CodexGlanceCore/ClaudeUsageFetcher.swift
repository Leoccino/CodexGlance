import Foundation

public enum ClaudeUsageError: LocalizedError, Equatable {
    case credentialsNotFound
    case unauthorized
    case refreshInProgress
    case saveFailed
    case rateLimited
    case httpStatus(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude Code sign-in not found. Run `claude` in Terminal and sign in."
        case .unauthorized:
            return "Claude Code sign-in expired. Run `claude` in Terminal and sign in again."
        case .refreshInProgress:
            return "Claude Code is refreshing its sign-in. Try again shortly."
        case .saveFailed:
            return "Could not save the refreshed Claude Code sign-in."
        case .rateLimited:
            return "Claude is limiting usage requests. Please try again later."
        case let .httpStatus(status):
            return "Claude usage request failed (HTTP \(status))."
        case let .invalidResponse(message):
            return "Claude returned invalid data: \(message)"
        }
    }
}

public final class ClaudeUsageFetcher: UsageMonitoring {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    // Refresh slightly early so a token never expires mid-request.
    private static let refreshMargin: TimeInterval = 60

    public typealias HTTPSend = (URLRequest) throws -> (data: Data, statusCode: Int)

    private let store: ClaudeCredentialStore
    private let loadAccountEmail: () -> String?
    private let send: HTTPSend
    private let now: () -> Date
    private let queue = DispatchQueue(label: "CodexGlance.ClaudeUsageFetcher", qos: .utility)
    private let callbackLock = NSLock()
    private var snapshotHandler: ((UsageSnapshot) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var lastSnapshot: UsageSnapshot?
    // A refreshed sign-in that could not be saved stays usable from memory.
    private var unsavedCredentials: ClaudeCredentials?

    public var onSnapshot: ((UsageSnapshot) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return snapshotHandler
        }
        set {
            callbackLock.lock()
            snapshotHandler = newValue
            callbackLock.unlock()
        }
    }

    public var onError: ((Error) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return errorHandler
        }
        set {
            callbackLock.lock()
            errorHandler = newValue
            callbackLock.unlock()
        }
    }

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            store: ClaudeCodeCredentialStore(environment: environment),
            loadAccountEmail: { ClaudeCredentialsLoader.accountEmail(environment: environment) },
            send: Self.sendSynchronously
        )
    }

    public init(
        store: ClaudeCredentialStore,
        loadAccountEmail: @escaping () -> String?,
        send: @escaping HTTPSend,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.loadAccountEmail = loadAccountEmail
        self.send = send
        self.now = now
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.fetchOnQueue()
                self.emit(snapshot: snapshot)
            } catch {
                self.emit(error: error)
            }
        }
    }

    public func shutdown() {}

    public func fetch() throws -> UsageSnapshot {
        var result: Result<UsageSnapshot, Error>!
        queue.sync {
            result = Result {
                try fetchOnQueue()
            }
        }
        return try result.get()
    }

    private func fetchOnQueue() throws -> UsageSnapshot {
        var credentials = try currentCredentials()
        if credentials.isExpired(at: now().addingTimeInterval(Self.refreshMargin)) {
            credentials = try refreshedCredentials(replacing: credentials)
        }

        var response = try send(usageRequest(accessToken: credentials.accessToken))
        if response.statusCode == 401 {
            // Revoked before its expiry time: refresh once and retry.
            credentials = try refreshedCredentials(replacing: credentials)
            response = try send(usageRequest(accessToken: credentials.accessToken))
        }

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw ClaudeUsageError.unauthorized
        case 429:
            // The usage endpoint throttles aggressive polling; the last reading
            // (with its original update time) is still the best answer.
            if let lastSnapshot {
                return lastSnapshot
            }
            throw ClaudeUsageError.rateLimited
        default:
            throw ClaudeUsageError.httpStatus(response.statusCode)
        }

        let snapshot = try ClaudeUsageMapper.snapshot(
            usageData: response.data,
            identity: AccountIdentity(email: loadAccountEmail(), plan: credentials.subscriptionType),
            now: now()
        )
        lastSnapshot = snapshot
        return snapshot
    }

    private func currentCredentials() throws -> ClaudeCredentials {
        let stored = try store.load()
        if let unsavedCredentials,
           (unsavedCredentials.expiresAt ?? .distantPast) > (stored.expiresAt ?? .distantPast) {
            return unsavedCredentials
        }
        return stored
    }

    private func refreshedCredentials(replacing stale: ClaudeCredentials) throws -> ClaudeCredentials {
        try store.withRefreshLock {
            // Claude Code may have refreshed while this waited for the lock.
            let current = try currentCredentials()
            if current.accessToken != stale.accessToken,
               !current.isExpired(at: now().addingTimeInterval(Self.refreshMargin)) {
                return current
            }
            guard let refreshToken = current.refreshToken else {
                throw ClaudeUsageError.unauthorized
            }

            let tokens = try requestTokenRefresh(refreshToken: refreshToken, scopes: current.scopes)
            let refreshed = current.applying(tokens)
            do {
                try store.save(tokens)
                unsavedCredentials = nil
            } catch {
                unsavedCredentials = refreshed
                throw error
            }
            return refreshed
        }
    }

    private func requestTokenRefresh(refreshToken: String, scopes: [String]) throws -> ClaudeRefreshedTokens {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID
        ]
        if !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }

        // Kept under the 10 s after which Claude Code treats the refresh lock as stale.
        var request = URLRequest(url: Self.tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexGlance", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let response = try send(request)
        switch response.statusCode {
        case 200:
            return try ClaudeUsageMapper.refreshedTokens(from: response.data, now: now())
        case 400, 401, 403:
            throw ClaudeUsageError.unauthorized
        case 429:
            throw ClaudeUsageError.rateLimited
        default:
            throw ClaudeUsageError.httpStatus(response.statusCode)
        }
    }

    private func usageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexGlance", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    private func emit(snapshot: UsageSnapshot) {
        callbackLock.lock()
        let handler = snapshotHandler
        callbackLock.unlock()
        handler?(snapshot)
    }

    private func emit(error: Error) {
        callbackLock.lock()
        let handler = errorHandler
        callbackLock.unlock()
        handler?(error)
    }

    private static let session = URLSession(configuration: .ephemeral)

    private static func sendSynchronously(_ request: URLRequest) throws -> (data: Data, statusCode: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(data: Data, statusCode: Int), Error> = .failure(
            ClaudeUsageError.invalidResponse("no response")
        )

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse, let data else {
                result = .failure(ClaudeUsageError.invalidResponse("no response"))
                return
            }
            result = .success((data, response.statusCode))
        }.resume()

        semaphore.wait()
        return try result.get()
    }
}

// The usage endpoint reports one object per window, keyed by duration and an
// optional model scope: `five_hour`, `seven_day`, `seven_day_opus`, ... Keys are
// parsed rather than hard-coded so new windows and model buckets still show up.
public enum ClaudeUsageMapper {
    public static func snapshot(usageData: Data, identity: AccountIdentity?, now: Date = Date()) throws -> UsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse("expected a JSON object")
        }
        guard let windows = windows(fromLimits: object["limits"]) ?? windows(fromWindowKeys: object) else {
            throw ClaudeUsageError.invalidResponse("no usage windows")
        }

        return UsageSnapshot(
            current: windows.current,
            weekly: windows.weekly,
            additionalLimits: windows.additional.sorted {
                ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending
            },
            credits: nil,
            identity: identity.flatMap { $0.email == nil && $0.plan == nil ? nil : $0 },
            updatedAt: now
        )
    }

    private typealias Windows = (current: RateWindow?, weekly: RateWindow?, additional: [RateLimitBucket])

    private static let limitGroupMinutes = ["session": 300, "weekly": 10_080]

    // Newer responses list every limit in `limits`, including model-scoped
    // weekly limits (such as one model's weekly cap) that have no legacy key.
    private static func windows(fromLimits value: Any?) -> Windows? {
        guard let limits = value as? [[String: Any]] else {
            return nil
        }

        var result: Windows = (nil, nil, [])
        for (index, limit) in limits.enumerated() {
            guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else {
                continue
            }

            let kind = limit["kind"] as? String ?? "limit"
            let group = limit["group"] as? String ?? kind
            let window = RateWindow(
                usedPercent: percent,
                windowMinutes: limitGroupMinutes[group],
                resetsAt: parseDate(limit["resets_at"])
            )
            if let scope = scopeName(limit["scope"]) {
                result.additional.append(RateLimitBucket(id: "\(kind)-\(index)", name: scope, primary: window, secondary: nil))
            } else if group == "session", result.current == nil {
                result.current = window
            } else if group == "weekly", result.weekly == nil {
                result.weekly = window
            } else {
                result.additional.append(
                    RateLimitBucket(id: "\(kind)-\(index)", name: displayName(forScope: kind), primary: window, secondary: nil)
                )
            }
        }

        return result.current == nil && result.weekly == nil && result.additional.isEmpty ? nil : result
    }

    private static func windows(fromWindowKeys object: [String: Any]) -> Windows? {
        var accountWindows: [RateWindow] = []
        var scopedBuckets: [RateLimitBucket] = []
        for (key, value) in object {
            guard
                let parsedKey = parseWindowKey(key),
                let window = makeWindow(value, minutes: parsedKey.minutes)
            else {
                continue
            }

            if let scope = parsedKey.scope {
                scopedBuckets.append(RateLimitBucket(id: key, name: displayName(forScope: scope), primary: window, secondary: nil))
            } else {
                accountWindows.append(window)
            }
        }

        guard !accountWindows.isEmpty || !scopedBuckets.isEmpty else {
            return nil
        }

        accountWindows.sort { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
        let extraAccountWindows = accountWindows.dropFirst(2).map { window in
            RateLimitBucket(id: "account-\(window.windowMinutes ?? 0)", name: "All models", primary: window, secondary: nil)
        }
        return (accountWindows.first, accountWindows.dropFirst().first, extraAccountWindows + scopedBuckets)
    }

    private static func scopeName(_ value: Any?) -> String? {
        guard let scope = value as? [String: Any] else {
            return nil
        }

        for key in ["model", "surface"] {
            if let name = scope[key] as? String, !name.isEmpty {
                return name
            }
            if let named = scope[key] as? [String: Any],
               let name = ["display_name", "name", "id"].lazy.compactMap({ named[$0] as? String }).first(where: { !$0.isEmpty }) {
                return name
            }
        }
        return nil
    }

    static func refreshedTokens(from data: Data, now: Date) throws -> ClaudeRefreshedTokens {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        else {
            throw ClaudeUsageError.invalidResponse("unexpected token refresh response")
        }

        return ClaudeRefreshedTokens(
            accessToken: accessToken,
            refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: now.addingTimeInterval(expiresIn),
            scopes: (object["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
        )
    }

    static func parseWindowKey(_ key: String) -> (minutes: Int, scope: String?)? {
        let parts = key.lowercased().split(separator: "_").map(String.init)
        guard
            parts.count >= 2,
            let count = Int(parts[0]) ?? numberWords[parts[0]],
            let unitMinutes = unitMinutes[parts[1]]
        else {
            return nil
        }

        let scope = parts.dropFirst(2).joined(separator: "_")
        return (count * unitMinutes, scope.isEmpty ? nil : scope)
    }

    private static func makeWindow(_ value: Any, minutes: Int) -> RateWindow? {
        guard
            let object = value as? [String: Any],
            let utilization = (object["utilization"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        return RateWindow(
            usedPercent: utilization,
            windowMinutes: minutes,
            resetsAt: parseDate(object["resets_at"] ?? object["resetsAt"])
        )
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let string = value as? String else {
            return nil
        }

        // Drop fractional seconds: the API sends microseconds, which
        // ISO8601DateFormatter does not reliably accept.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoFormatter.date(from: trimmed)
    }

    private static func displayName(forScope scope: String) -> String {
        scope.split(separator: "_").map { word in
            word == "oauth" ? "OAuth" : word.prefix(1).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "fourteen": 14, "thirty": 30
    ]

    private static let unitMinutes: [String: Int] = [
        "minute": 1, "minutes": 1,
        "hour": 60, "hours": 60,
        "day": 1_440, "days": 1_440,
        "week": 10_080, "weeks": 10_080
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
