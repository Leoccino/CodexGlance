import Foundation

public struct ClaudeCredentials: Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date?,
        scopes: [String] = [],
        subscriptionType: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
    }

    func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    func applying(_ tokens: ClaudeRefreshedTokens) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? refreshToken,
            expiresAt: tokens.expiresAt,
            scopes: tokens.scopes ?? scopes,
            subscriptionType: subscriptionType
        )
    }
}

public struct ClaudeRefreshedTokens: Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scopes: [String]?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String]?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

public protocol ClaudeCredentialStore: AnyObject {
    func load() throws -> ClaudeCredentials
    // Runs `body` while holding the lock Claude Code takes before it refreshes.
    func withRefreshLock<T>(_ body: () throws -> T) throws -> T
    func save(_ tokens: ClaudeRefreshedTokens) throws
}

// Claude Code keeps its OAuth sign-in in the login keychain on macOS and in
// `.credentials.json` elsewhere. When the access token has expired, CodexGlance
// refreshes it the way Claude Code does and writes it back to the same place,
// under Claude Code's own locks, so both keep sharing one sign-in.
public final class ClaudeCodeCredentialStore: ClaudeCredentialStore {
    private enum Source {
        case keychain
        case file
    }

    private let environment: [String: String]
    private var lastSource: Source?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func load() throws -> ClaudeCredentials {
        if let credentials = ClaudeKeychain.read(service: ClaudeCredentialsLoader.keychainService).flatMap(ClaudeCredentialsLoader.parse) {
            lastSource = .keychain
            return credentials
        }
        if let credentials = FileManager.default.contents(atPath: credentialsPath).flatMap(ClaudeCredentialsLoader.parse) {
            lastSource = .file
            return credentials
        }

        throw ClaudeUsageError.credentialsNotFound
    }

    public func withRefreshLock<T>(_ body: () throws -> T) throws -> T {
        let configDirectory = ClaudeCredentialsLoader.configDirectory(environment: environment)
        try FileManager.default.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)

        // Same two locks, in the same order, as Claude Code's own refresh.
        let refreshLock = try ClaudeDirectoryLock.acquire(at: "\(configDirectory)/.oauth_refresh.lock", staleAfter: 10)
        defer { refreshLock.release() }
        let legacyPath = URL(fileURLWithPath: configDirectory).resolvingSymlinksInPath().path + ".lock"
        let legacyLock = try ClaudeDirectoryLock.acquire(at: legacyPath, staleAfter: 10)
        defer { legacyLock.release() }

        return try body()
    }

    public func save(_ tokens: ClaudeRefreshedTokens) throws {
        let configDirectory = ClaudeCredentialsLoader.configDirectory(environment: environment)
        let writeLock = try ClaudeDirectoryLock.acquire(at: "\(configDirectory)/.storage-write.lock", staleAfter: 15)
        defer { writeLock.release() }

        switch lastSource {
        case .keychain?:
            let service = ClaudeCredentialsLoader.keychainService
            guard
                let stored = ClaudeKeychain.read(service: service),
                let merged = ClaudeCredentialsLoader.mergedCredentialsData(stored, with: tokens)
            else {
                throw ClaudeUsageError.credentialsNotFound
            }
            try ClaudeKeychain.write(merged, service: service, account: ClaudeKeychain.account(service: service) ?? NSUserName())
            guard ClaudeKeychain.read(service: service).flatMap(ClaudeCredentialsLoader.parse)?.accessToken == tokens.accessToken else {
                throw ClaudeUsageError.saveFailed
            }
        case .file?:
            guard
                let stored = FileManager.default.contents(atPath: credentialsPath),
                let merged = ClaudeCredentialsLoader.mergedCredentialsData(stored, with: tokens)
            else {
                throw ClaudeUsageError.credentialsNotFound
            }
            let url = URL(fileURLWithPath: credentialsPath)
            try merged.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        case nil:
            throw ClaudeUsageError.credentialsNotFound
        }
    }

    private var credentialsPath: String {
        ClaudeCredentialsLoader.credentialsPath(environment: environment)
    }
}

public enum ClaudeCredentialsLoader {
    static let keychainService = "Claude Code-credentials"

    static func load(
        environment: [String: String],
        readKeychain: (String) -> Data?,
        readFile: (String) -> Data?
    ) throws -> ClaudeCredentials {
        if let credentials = readKeychain(keychainService).flatMap(parse) {
            return credentials
        }
        if let credentials = readFile(credentialsPath(environment: environment)).flatMap(parse) {
            return credentials
        }

        throw ClaudeUsageError.credentialsNotFound
    }

    public static func accountEmail(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        FileManager.default.contents(atPath: profilePath(environment: environment)).flatMap(parseAccountEmail)
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        struct Payload: Decodable {
            let claudeAiOauth: OAuth?
        }
        struct OAuth: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresAt: Double?
            let scopes: [String]?
            let subscriptionType: String?
        }

        guard
            let oauth = (try? JSONDecoder().decode(Payload.self, from: data))?.claudeAiOauth,
            let token = clean(oauth.accessToken)
        else {
            return nil
        }

        return ClaudeCredentials(
            accessToken: token,
            refreshToken: clean(oauth.refreshToken),
            expiresAt: oauth.expiresAt.map { value in
                // Claude Code stores milliseconds; tolerate seconds too.
                Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
            },
            scopes: oauth.scopes ?? [],
            subscriptionType: clean(oauth.subscriptionType)
        )
    }

    // Replaces only the token fields, keeping everything else Claude Code stores
    // next to them (MCP sign-ins, plan, rate limit tier, ...).
    static func mergedCredentialsData(_ data: Data, with tokens: ClaudeRefreshedTokens) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = tokens.accessToken
        if let refreshToken = tokens.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = Int64((tokens.expiresAt.timeIntervalSince1970 * 1_000).rounded())
        if let scopes = tokens.scopes {
            oauth["scopes"] = scopes
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    static func parseAccountEmail(_ data: Data) -> String? {
        struct Profile: Decodable {
            let oauthAccount: Account?
        }
        struct Account: Decodable {
            let emailAddress: String?
        }

        return clean((try? JSONDecoder().decode(Profile.self, from: data))?.oauthAccount?.emailAddress)
    }

    static func configDirectory(environment: [String: String]) -> String {
        clean(environment["CLAUDE_CONFIG_DIR"]) ?? "\(homeDirectory(environment: environment))/.claude"
    }

    static func credentialsPath(environment: [String: String]) -> String {
        "\(configDirectory(environment: environment))/.credentials.json"
    }

    static func profilePath(environment: [String: String]) -> String {
        if let configDir = clean(environment["CLAUDE_CONFIG_DIR"]) {
            return "\(configDir)/.claude.json"
        }
        return "\(homeDirectory(environment: environment))/.claude.json"
    }

    private static func homeDirectory(environment: [String: String]) -> String {
        clean(environment["HOME"]) ?? NSHomeDirectory()
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}

// Goes through `/usr/bin/security`, like Claude Code itself, so the keychain
// item's access list (which already trusts `security`) applies unchanged.
enum ClaudeKeychain {
    // Commands longer than this go on the command line instead of stdin.
    private static let interactiveCommandLimit = 4_000

    static func read(service: String) -> Data? {
        let result = run(["find-generic-password", "-s", service, "-w"])
        return result.status == 0 ? result.output : nil
    }

    static func account(service: String) -> String? {
        let result = run(["find-generic-password", "-s", service])
        guard result.status == 0 else {
            return nil
        }
        return parseAccount(fromAttributes: String(decoding: result.output, as: UTF8.self))
    }

    static func parseAccount(fromAttributes text: String) -> String? {
        guard let range = text.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression) else {
            return nil
        }
        let match = text[range]
        let value = match.dropFirst(#""acct"<blob>=""#.count).dropLast()
        return value.isEmpty ? nil : String(value)
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        // Prefer stdin so the token never shows up in the process list.
        let result = command.utf8.count <= interactiveCommandLimit
            ? run(["-i"], input: Data(command.utf8))
            : run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        guard result.status == 0 else {
            throw ClaudeUsageError.saveFailed
        }
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        }

        do {
            try process.run()
        } catch {
            return (-1, Data())
        }

        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

// A `mkdir` lock compatible with the `proper-lockfile` locks Claude Code uses:
// the directory's existence is the lock and an old modification time means
// its owner died.
final class ClaudeDirectoryLock {
    private let path: String

    private init(path: String) {
        self.path = path
    }

    static func acquire(
        at path: String,
        staleAfter: TimeInterval,
        timeout: TimeInterval = 15,
        fileManager: FileManager = .default
    ) throws -> ClaudeDirectoryLock {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
                return ClaudeDirectoryLock(path: path)
            } catch {
                guard fileManager.fileExists(atPath: path) else {
                    throw error
                }
            }

            let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > staleAfter {
                try? fileManager.removeItem(atPath: path)
                continue
            }
            guard Date() < deadline else {
                throw ClaudeUsageError.refreshInProgress
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    func release() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
