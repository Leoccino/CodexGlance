import AppKit
import CodexGlanceCore

if CommandLine.arguments.contains("--print") {
    let arguments = CommandLine.arguments
    var providers = UsageProvider.allCases
    if let flagIndex = arguments.firstIndex(of: "--provider") {
        guard
            flagIndex + 1 < arguments.count,
            let provider = UsageProvider(rawValue: arguments[flagIndex + 1].lowercased())
        else {
            let names = UsageProvider.allCases.map(\.rawValue).joined(separator: "|")
            fputs("Usage: CodexGlance --print [--provider \(names)]\n", stderr)
            exit(2)
        }
        providers = [provider]
    }

    var failures = 0
    for (index, provider) in providers.enumerated() {
        if providers.count > 1 {
            print(index == 0 ? "[\(provider.displayName)]" : "\n[\(provider.displayName)]")
        }

        do {
            let fetcher: UsageFetching = provider == .codex ? CodexUsageFetcher() : ClaudeUsageFetcher()
            let snapshot = try fetcher.fetch()
            let display = UsageDisplayFormatter.display(for: snapshot)
            print(display.title)
            if let accountLine = display.accountLine {
                print(accountLine)
            }
            for usageLine in display.usageLines {
                print(usageLine)
            }
            for additionalLimitLine in display.additionalLimitLines {
                print(additionalLimitLine)
            }
            if let resetCreditsLine = display.resetCreditsLine {
                print(resetCreditsLine)
            }
            if let creditsLine = display.creditsLine {
                print(creditsLine)
            }
            print(display.updatedLine)
        } catch {
            fputs("\(provider.displayName) usage unavailable: \(error.localizedDescription)\n", stderr)
            failures += 1
        }
    }
    exit(failures == providers.count ? 1 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
