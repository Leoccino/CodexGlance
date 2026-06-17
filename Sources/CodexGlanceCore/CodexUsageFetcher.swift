import Foundation

public protocol CodexUsageFetching {
    func fetch() throws -> CodexUsageSnapshot
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
}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let planType: String?
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
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
