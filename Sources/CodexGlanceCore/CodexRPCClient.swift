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

public final class CodexRPCClient: CodexRPCTransport {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let reader: LineReader
    private let stderrText: TextCollector
    private var nextID = 1

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
    }

    public func initialize(timeout: TimeInterval = 8) throws {
        _ = try call(
            method: "initialize",
            params: ["clientInfo": ["name": "CodexGlance", "version": "0.1.0"]],
            timeout: timeout
        )
        try notify(method: "initialized", params: nil)
    }

    public func call(method: String, params: [String: Any]? = nil, timeout: TimeInterval = 3) throws -> [String: Any] {
        let id = nextID
        nextID += 1

        try send(["id": id, "method": method, "params": params ?? [:]])

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexRPCError.timeout(method)
            }

            let message = try readMessage(timeout: remaining)
            if message["id"] == nil {
                continue
            }

            guard jsonID(message["id"]) == id else {
                continue
            }

            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? String(describing: error)
                throw CodexRPCError.requestFailed(text)
            }

            guard let result = message["result"] as? [String: Any] else {
                throw CodexRPCError.malformedResponse("missing result")
            }

            return result
        }
    }

    public func notify(method: String, params: [String: Any]? = nil) throws {
        try send(["method": method, "params": params ?? [:]])
    }

    public func shutdown() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdin.fileHandleForWriting.write(data)
        stdin.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readMessage(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexRPCError.timeout("response")
            }

            let data: Data
            do {
                data = try reader.nextLine(timeout: remaining)
            } catch CodexRPCError.malformedResponse(let message) {
                let stderr = stderrText.snapshot()
                if stderr.isEmpty {
                    throw CodexRPCError.malformedResponse(message)
                }
                throw CodexRPCError.malformedResponse("\(message): \(stderr)")
            }

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            return object
        }
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

public enum CodexExecutableLocator {
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = clean(environment["CODEX_BIN"]) {
            return explicit
        }

        let fileManager = FileManager.default
        let preferredCandidates = [
            "/Applications/Codex.app/Contents/Resources/codex"
        ]

        for candidate in preferredCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        for directory in effectivePath(environment: environment).split(separator: ":") {
            let candidate = "\(directory)/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
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
