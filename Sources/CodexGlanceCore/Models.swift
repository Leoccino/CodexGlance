import Foundation

public struct RateWindow: Equatable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var clampedUsedPercent: Double {
        min(100, max(0, usedPercent))
    }

    public var roundedUsedPercent: Int {
        Int(clampedUsedPercent.rounded())
    }

    public var remainingPercent: Double {
        max(0, 100 - clampedUsedPercent)
    }
}

public struct Credits: Equatable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct AccountIdentity: Equatable {
    public let email: String?
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

public struct RateLimitBucket: Equatable {
    public let id: String
    public let name: String?
    public let primary: RateWindow?
    public let secondary: RateWindow?

    public init(id: String, name: String?, primary: RateWindow?, secondary: RateWindow?) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CodexUsageSnapshot: Equatable {
    public let current: RateWindow?
    public let weekly: RateWindow?
    public let additionalLimits: [RateLimitBucket]
    public let resetCreditsAvailable: Int?
    public let credits: Credits?
    public let identity: AccountIdentity?
    public let updatedAt: Date

    public init(
        current: RateWindow?,
        weekly: RateWindow?,
        additionalLimits: [RateLimitBucket] = [],
        resetCreditsAvailable: Int? = nil,
        credits: Credits?,
        identity: AccountIdentity?,
        updatedAt: Date
    ) {
        self.current = current
        self.weekly = weekly
        self.additionalLimits = additionalLimits
        self.resetCreditsAvailable = resetCreditsAvailable
        self.credits = credits
        self.identity = identity
        self.updatedAt = updatedAt
    }
}

public struct CodexUsageDisplay: Equatable {
    public let title: String
    public let usageLines: [String]
    public let additionalLimitLines: [String]
    public let resetCreditsLine: String?
    public let creditsLine: String?
    public let accountLine: String?
    public let updatedLine: String

    public init(
        title: String,
        usageLines: [String],
        additionalLimitLines: [String],
        resetCreditsLine: String?,
        creditsLine: String?,
        accountLine: String?,
        updatedLine: String
    ) {
        self.title = title
        self.usageLines = usageLines
        self.additionalLimitLines = additionalLimitLines
        self.resetCreditsLine = resetCreditsLine
        self.creditsLine = creditsLine
        self.accountLine = accountLine
        self.updatedLine = updatedLine
    }
}

public struct CodexUsageMenuLine: Equatable {
    public let label: String
    public let remainingPercent: Int?
    public let resetText: String?
    public let resetTimeFractionRemaining: Double?

    public init(
        label: String,
        remainingPercent: Int?,
        resetText: String?,
        resetTimeFractionRemaining: Double? = nil
    ) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetText = resetText
        self.resetTimeFractionRemaining = resetTimeFractionRemaining
    }
}
