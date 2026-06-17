import AppKit
import CodexGlanceCore

if CommandLine.arguments.contains("--print") {
    do {
        let snapshot = try CodexUsageFetcher().fetch()
        let display = CodexUsageDisplayFormatter.display(for: snapshot)
        print(display.title)
        if let accountLine = display.accountLine {
            print(accountLine)
        }
        print(display.currentLine)
        print(display.weeklyLine)
        if let creditsLine = display.creditsLine {
            print(creditsLine)
        }
        print(display.updatedLine)
        exit(0)
    } catch {
        fputs("Codex usage unavailable: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
