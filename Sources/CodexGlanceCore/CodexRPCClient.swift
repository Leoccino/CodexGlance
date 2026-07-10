import Foundation

public enum CodexRPCError: LocalizedError, Equatable {
    case codexNotFound
    case startFailed(String)
    case requestFailed(String)
    case timeout(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Could not find the codex executable."
        case let .startFailed(message):
            return "Could not start codex app-server: \(message)"
        case let .requestFailed(message):
            return "Codex RPC request failed: \(message)"
        case let .timeout(method):
            return "Timed out waiting for \(method)."
        case let .malformedResponse(message):
            return "Codex returned invalid data: \(message)"
        }
    }
}

public protocol CodexRPCTransport {
    func call(method: String, params: [String: Any]?, timeout: TimeInterval) throws -> [String: Any]
    func notify(method: String, params: [String: Any]?) throws
    func shutdown()
}

public typealias CodexRPCNotificationHandler = ([String: Any]) -> Void
public typealias CodexRPCDisconnectHandler = (Error?) -> Void

public final class CodexRPCClient: CodexRPCTransport {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let reader: LineReader
    private let stderrText: TextCollector
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let dispatchQueue = DispatchQueue(label: "CodexGlance.CodexRPCClient.dispatch", qos: .utility)
    private var pending: [Int: PendingCall] = [:]
    private var notificationHandler: CodexRPCNotificationHandler?
    private var disconnectHandler: CodexRPCDisconnectHandler?
    private var nextID = 1
    private var isShutdown = false

    public init(
        executablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let executable = executablePath ?? CodexExecutableLocator.find(environment: environment) else {
            throw CodexRPCError.codexNotFound
        }

        process = Process()
        stdin = Pipe()
        stdout = Pipe()
        stderr = Pipe()
        reader = LineReader()
        stderrText = TextCollector()

        var env = environment
        env["PATH"] = CodexExecutableLocator.effectivePath(environment: environment)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server"]
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [reader] handle in
            reader.append(handle.availableData)
        }

        stderr.fileHandleForReading.readabilityHandler = { [stderrText] handle in
            stderrText.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CodexRPCError.startFailed(error.localizedDescription)
        }

        startDispatchLoop()
    }

    public func initialize(timeout: TimeInterval = 8) throws {
        _ = try call(
            method: "initialize",
            params: [
                "clientInfo": ["name": "CodexGlance", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ],
            timeout: timeout
        )
        try notify(method: "initialized", params: nil)
    }

    public func call(method: String, params: [String: Any]? = nil, timeout: TimeInterval = 3) throws -> [String: Any] {
        let id = nextRequestID()
        let pendingCall = PendingCall(method: method)
        setPendingCall(pendingCall, for: id)

        do {
            try send(["id": id, "method": method, "params": params ?? [:]])
        } catch {
            _ = removePendingCall(for: id)
            throw error
        }

        do {
            return try pendingCall.wait(timeout: timeout)
        } catch {
            _ = removePendingCall(for: id)
            throw error
        }
    }

    public func notify(method: String, params: [String: Any]? = nil) throws {
        try send(["method": method, "params": params ?? [:]])
    }

    public func setNotificationHandler(_ handler: CodexRPCNotificationHandler?) {
        stateLock.lock()
        notificationHandler = handler
        stateLock.unlock()
    }

    public func setDisconnectHandler(_ handler: CodexRPCDisconnectHandler?) {
        stateLock.lock()
        disconnectHandler = handler
        stateLock.unlock()
    }

    public func shutdown() {
        stateLock.lock()
        if isShutdown {
            stateLock.unlock()
            return
        }
        isShutdown = true
        let pendingCalls = pending.values
        pending.removeAll()
        notificationHandler = nil
        disconnectHandler = nil
        stateLock.unlock()

        let error = CodexRPCError.malformedResponse("codex app-server stopped")
        for pendingCall in pendingCalls {
            pendingCall.complete(.failure(error))
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        stdin.fileHandleForWriting.write(data)
        stdin.fileHandleForWriting.write(Data([0x0A]))
    }

    private func startDispatchLoop() {
        dispatchQueue.async { [weak self] in
            self?.dispatchMessages()
        }
    }

    private func dispatchMessages() {
        while true {
            do {
                let data = try reader.nextLine()
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                handleIncomingMessage(object)
            } catch CodexRPCError.malformedResponse(let message) {
                let stderr = stderrText.snapshot()
                let error: CodexRPCError
                if stderr.isEmpty {
                    error = .malformedResponse(message)
                } else {
                    error = .malformedResponse("\(message): \(stderr)")
                }
                failPendingCalls(error)
                emitDisconnect(error)
                return
            } catch {
                failPendingCalls(error)
                emitDisconnect(error)
                return
            }
        }
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        if let id = jsonID(message["id"]), message["result"] != nil || message["error"] != nil {
            guard let pendingCall = removePendingCall(for: id) else {
                return
            }
            pendingCall.complete(result(from: message))
            return
        }

        if message["method"] != nil {
            emitNotification(message)
        }
    }

    private func result(from message: [String: Any]) -> Result<[String: Any], Error> {
        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? String(describing: error)
            return .failure(CodexRPCError.requestFailed(text))
        }

        guard let result = message["result"] as? [String: Any] else {
            return .failure(CodexRPCError.malformedResponse("missing result"))
        }

        return .success(result)
    }

    private func nextRequestID() -> Int {
        stateLock.lock()
        let id = nextID
        nextID += 1
        stateLock.unlock()
        return id
    }

    private func setPendingCall(_ pendingCall: PendingCall, for id: Int) {
        stateLock.lock()
        pending[id] = pendingCall
        stateLock.unlock()
    }

    private func removePendingCall(for id: Int) -> PendingCall? {
        stateLock.lock()
        let pendingCall = pending.removeValue(forKey: id)
        stateLock.unlock()
        return pendingCall
    }

    private func failPendingCalls(_ error: Error) {
        stateLock.lock()
        let pendingCalls = pending.values
        pending.removeAll()
        stateLock.unlock()

        for pendingCall in pendingCalls {
            pendingCall.complete(.failure(error))
        }
    }

    private func emitNotification(_ message: [String: Any]) {
        stateLock.lock()
        let handler = notificationHandler
        stateLock.unlock()
        handler?(message)
    }

    private func emitDisconnect(_ error: Error?) {
        stateLock.lock()
        let handler = disconnectHandler
        stateLock.unlock()
        handler?(error)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

private final class PendingCall {
    private let method: String
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<[String: Any], Error>?

    init(method: String) {
        self.method = method
    }

    func complete(_ result: Result<[String: Any], Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> [String: Any] {
        let status = semaphore.wait(timeout: .now() + timeout)
        if status == .timedOut {
            throw CodexRPCError.timeout(method)
        }

        lock.lock()
        let result = self.result
        lock.unlock()

        guard let result else {
            throw CodexRPCError.malformedResponse("missing response for \(method)")
        }

        return try result.get()
    }
}

public enum CodexExecutableLocator {
    static let bundledExecutableCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex"
    ]

    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        find(environment: environment) { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func find(
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> String? {
        if let explicit = clean(environment["CODEX_BIN"]) {
            return explicit
        }

        for candidate in bundledExecutableCandidates where isExecutable(candidate) {
            return candidate
        }

        for directory in effectivePath(environment: environment).split(separator: ":") {
            let candidate = "\(directory)/codex"
            if isExecutable(candidate) {
                return candidate
            }
        }

        return nil
    }

    public static func effectivePath(environment: [String: String]) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let existing = environment["PATH"] ?? ""
        let additions = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.npm-global/bin",
            "\(home)/Documents/claw/.npm-global/bin"
        ]

        return ([existing] + additions)
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}

private final class TextCollector {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return
        }

        lock.lock()
        text.append(chunk)
        if text.count > 4_000 {
            text.removeFirst(text.count - 4_000)
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LineReader {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        if data.isEmpty {
            closed = true
            semaphore.signal()
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
                semaphore.signal()
            }
        }
    }

    func nextLine() throws -> Data {
        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            if closed {
                lock.unlock()
                throw CodexRPCError.malformedResponse("codex app-server closed stdout")
            }
            lock.unlock()

            semaphore.wait()
        }
    }

    func nextLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            if closed {
                lock.unlock()
                throw CodexRPCError.malformedResponse("codex app-server closed stdout")
            }
            lock.unlock()

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexRPCError.timeout("response")
            }

            let result = semaphore.wait(timeout: .now() + remaining)
            if result == .timedOut {
                throw CodexRPCError.timeout("response")
            }
        }
    }
}
