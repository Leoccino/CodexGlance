import Foundation

public protocol CodexUsageFetching {
    func fetch() throws -> CodexUsageSnapshot
}

public protocol CodexUsageMonitoring: AnyObject, CodexUsageFetching {
    var onSnapshot: ((CodexUsageSnapshot) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start()
    func shutdown()
}

public final class CodexUsageFetcher: CodexUsageFetching {
    private let makeTransport: () throws -> CodexRPCTransport

    public convenience init() {
        self.init {
            let client = try CodexRPCClient()
            try client.initialize()
            return client
        }
    }

    public init(makeTransport: @escaping () throws -> CodexRPCTransport) {
        self.makeTransport = makeTransport
    }

    public func fetch() throws -> CodexUsageSnapshot {
        let transport = try makeTransport()
        defer { transport.shutdown() }

        do {
            let limitsResult = try transport.call(method: "account/rateLimits/read", params: nil, timeout: 5)
            let accountResult = try? transport.call(method: "account/read", params: nil, timeout: 3)
            return try CodexUsageMapper.snapshot(limitsResult: limitsResult, accountResult: accountResult)
        } catch CodexRPCError.requestFailed(let message) {
            if let snapshot = CodexUsageMapper.snapshotFromErrorMessage(message) {
                return snapshot
            }
            throw CodexRPCError.requestFailed(message)
        }
    }
}

public final class CodexUsageMonitor: CodexUsageMonitoring {
    private let makeClient: () throws -> CodexRPCClient
    private let queue = DispatchQueue(label: "CodexGlance.CodexUsageMonitor", qos: .utility)
    private let callbackLock = NSLock()
    private var snapshotHandler: ((CodexUsageSnapshot) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var transport: CodexRPCClient?
    private var latestAccountResult: [String: Any]?
    private var isStarted = false

    public var onSnapshot: ((CodexUsageSnapshot) -> Void)? {
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

    public convenience init() {
        self.init {
            try CodexRPCClient()
        }
    }

    public init(makeClient: @escaping () throws -> CodexRPCClient) {
        self.makeClient = makeClient
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStarted else { return }
            self.isStarted = true
            self.refreshAndEmitOnQueue()
        }
    }

    public func shutdown() {
        queue.sync {
            isStarted = false
            resetTransportOnQueue()
        }
    }

    public func fetch() throws -> CodexUsageSnapshot {
        var result: Result<CodexUsageSnapshot, Error>!
        queue.sync {
            result = Result {
                try fetchOnQueue()
            }
        }
        return try result.get()
    }

    private func refreshAndEmitOnQueue() {
        do {
            let snapshot = try fetchOnQueue()
            emitSnapshot(snapshot)
        } catch {
            emitError(error)
        }
    }

    private func fetchOnQueue() throws -> CodexUsageSnapshot {
        let transport = try transportOnQueue()
        do {
            return try readSnapshot(using: transport)
        } catch {
            resetTransportOnQueue()
            throw error
        }
    }

    private func transportOnQueue() throws -> CodexRPCClient {
        if let transport {
            return transport
        }

        let client = try makeClient()
        client.setNotificationHandler { [weak self] message in
            self?.handleNotification(message)
        }
        client.setDisconnectHandler { [weak self, weak client] error in
            self?.handleDisconnect(from: client, error: error)
        }

        do {
            try client.initialize()
        } catch {
            client.shutdown()
            throw error
        }

        transport = client
        return client
    }

    private func readSnapshot(using transport: CodexRPCTransport) throws -> CodexUsageSnapshot {
        do {
            let limitsResult = try transport.call(method: "account/rateLimits/read", params: nil, timeout: 5)
            let accountResult = try? transport.call(method: "account/read", params: nil, timeout: 3)
            latestAccountResult = accountResult
            return try CodexUsageMapper.snapshot(limitsResult: limitsResult, accountResult: accountResult)
        } catch CodexRPCError.requestFailed(let message) {
            if let snapshot = CodexUsageMapper.snapshotFromErrorMessage(message) {
                return snapshot
            }
            throw CodexRPCError.requestFailed(message)
        }
    }

    private func handleNotification(_ message: [String: Any]) {
        queue.async { [weak self] in
            self?.handleNotificationOnQueue(message)
        }
    }

    private func handleNotificationOnQueue(_ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            return
        }

        switch method {
        case "account/rateLimits/updated":
            guard let rateLimits = rateLimitsPayload(from: message) else {
                return
            }

            do {
                let snapshot = try CodexUsageMapper.snapshot(
                    rateLimits: rateLimits,
                    accountResult: latestAccountResult
                )
                emitSnapshot(snapshot)
            } catch {
                emitError(error)
            }
        case "account/updated", "account/login/completed":
            refreshAndEmitOnQueue()
        default:
            break
        }
    }

    private func rateLimitsPayload(from message: [String: Any]) -> [String: Any]? {
        guard let params = message["params"] as? [String: Any] else {
            return nil
        }

        if let rateLimits = params["rateLimits"] as? [String: Any] {
            return rateLimits
        }
        if let rateLimits = params["rate_limits"] as? [String: Any] {
            return rateLimits
        }
        if params["primary"] != nil || params["secondary"] != nil {
            return params
        }

        return nil
    }

    private func handleDisconnect(from client: CodexRPCClient?, error: Error?) {
        queue.async { [weak self, weak client] in
            guard let self else { return }
            if let client, self.transport !== client {
                return
            }

            self.transport = nil
            if let error {
                self.emitError(error)
            }
        }
    }

    private func resetTransportOnQueue() {
        let oldTransport = transport
        transport = nil
        oldTransport?.shutdown()
    }

    private func emitSnapshot(_ snapshot: CodexUsageSnapshot) {
        callbackLock.lock()
        let handler = snapshotHandler
        callbackLock.unlock()
        handler?(snapshot)
    }

    private func emitError(_ error: Error) {
        callbackLock.lock()
        let handler = errorHandler
        callbackLock.unlock()
        handler?(error)
    }
}

public enum CodexUsageMapper {
    public static func snapshot(limitsResult: [String: Any], accountResult: [String: Any]?, now: Date = Date()) throws -> CodexUsageSnapshot {
        let limitsData = try JSONSerialization.data(withJSONObject: limitsResult)
        let limits = try JSONDecoder().decode(RPCRateLimitsResponse.self, from: limitsData).rateLimits
        let account = try accountResult.flatMap { result -> RPCAccountResponse? in
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(RPCAccountResponse.self, from: data)
        }

        return CodexUsageSnapshot(
            current: makeWindow(limits.primary),
            weekly: makeWindow(limits.secondary),
            credits: limits.credits.map { Credits(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance) },
            identity: makeIdentity(account: account, fallbackPlan: limits.planType),
            updatedAt: now
        )
    }

    public static func snapshot(rateLimits: [String: Any], accountResult: [String: Any]?, now: Date = Date()) throws -> CodexUsageSnapshot {
        try snapshot(limitsResult: ["rateLimits": rateLimits], accountResult: accountResult, now: now)
    }

    public static func snapshotFromErrorMessage(_ message: String, now: Date = Date()) -> CodexUsageSnapshot? {
        guard let body = extractJSONObject(after: "body=", in: message),
              let data = body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RPCRateLimitsErrorBody.self, from: data) else {
            return nil
        }

        return CodexUsageSnapshot(
            current: makeWindow(decoded.rateLimit?.primaryWindow),
            weekly: makeWindow(decoded.rateLimit?.secondaryWindow),
            credits: decoded.credits.map { credit in
                Credits(
                    hasCredits: credit.balance != nil,
                    unlimited: false,
                    balance: credit.balance.map { String($0) }
                )
            },
            identity: AccountIdentity(email: clean(decoded.email), plan: clean(decoded.planType)),
            updatedAt: now
        )
    }

    private static func makeIdentity(account: RPCAccountResponse?, fallbackPlan: String?) -> AccountIdentity? {
        if let details = account?.account, details.type.lowercased() == "chatgpt" {
            return AccountIdentity(email: clean(details.email), plan: clean(details.planType ?? fallbackPlan))
        }

        if let fallbackPlan = clean(fallbackPlan) {
            return AccountIdentity(email: nil, plan: fallbackPlan)
        }

        return nil
    }

    private static func makeWindow(_ window: RPCRateLimitWindow?) -> RateWindow? {
        guard let window else {
            return nil
        }

        return RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowDurationMins,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func makeWindow(_ window: RPCErrorRateLimitWindow?) -> RateWindow? {
        guard let window else {
            return nil
        }

        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds.map { $0 / 60 },
            resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func extractJSONObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else {
            return nil
        }

        let suffix = text[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaped = false

        for index in suffix[start...].indices {
            let character = suffix[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[start...index])
                }
            default:
                break
            }
        }

        return nil
    }
}

private struct RPCAccountResponse: Decodable {
    let account: RPCAccountDetails?
    let requiresOpenaiAuth: Bool?
}

private struct RPCAccountDetails: Decodable {
    let type: String
    let email: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
        case plan_type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .plan_type)
    }
}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rate_limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rateLimits = try container.decodeIfPresent(RPCRateLimitSnapshot.self, forKey: .rateLimits) {
            self.rateLimits = rateLimits
        } else {
            self.rateLimits = try container.decode(RPCRateLimitSnapshot.self, forKey: .rate_limits)
        }
    }
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType
        case plan_type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decodeIfPresent(RPCRateLimitWindow.self, forKey: .primary)
        secondary = try container.decodeIfPresent(RPCRateLimitWindow.self, forKey: .secondary)
        credits = try container.decodeIfPresent(RPCCreditsSnapshot.self, forKey: .credits)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .plan_type)
    }
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case used_percent
        case windowDurationMins
        case window_duration_mins
        case limitWindowSeconds
        case limit_window_seconds
        case resetsAt
        case resets_at
        case resetAt
        case reset_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeFlexibleDouble(keys: [.usedPercent, .used_percent])

        if let minutes = try container.decodeFlexibleIntIfPresent(keys: [.windowDurationMins, .window_duration_mins]) {
            windowDurationMins = minutes
        } else if let seconds = try container.decodeFlexibleIntIfPresent(keys: [.limitWindowSeconds, .limit_window_seconds]) {
            windowDurationMins = seconds / 60
        } else {
            windowDurationMins = nil
        }

        resetsAt = try container.decodeFlexibleIntIfPresent(keys: [.resetsAt, .resets_at, .resetAt, .reset_at])
    }
}

private struct RPCCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

private struct RPCRateLimitsErrorBody: Decodable {
    let email: String?
    let planType: String?
    let rateLimit: RPCErrorRateLimitDetails?
    let credits: RPCErrorCreditDetails?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private struct RPCErrorRateLimitDetails: Decodable {
    let primaryWindow: RPCErrorRateLimitWindow?
    let secondaryWindow: RPCErrorRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct RPCErrorRateLimitWindow: Decodable {
    let usedPercent: Int
    let limitWindowSeconds: Int?
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private struct RPCErrorCreditDetails: Decodable {
    let balance: Double?
}

private extension KeyedDecodingContainer where K == RPCRateLimitWindow.CodingKeys {
    func decodeFlexibleDouble(keys: [K]) throws -> Double {
        for key in keys {
            if let value = try decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: codingPath, debugDescription: "Missing numeric value")
        )
    }

    func decodeFlexibleIntIfPresent(keys: [K]) throws -> Int? {
        for key in keys {
            if let value = try decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
        }

        return nil
    }
}
