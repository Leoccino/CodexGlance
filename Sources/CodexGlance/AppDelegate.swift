import AppKit
import CodexGlanceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher: CodexUsageFetching
    private var timer: Timer?
    private var latestSnapshot: CodexUsageSnapshot?
    private var latestError: Error?
    private var isRefreshing = false

    init(fetcher: CodexUsageFetching = CodexUsageFetcher()) {
        self.fetcher = fetcher
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusButton()
        setStatusTitle(CodexUsageDisplayFormatter.menuTitle(for: nil))
        rebuildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func refreshMenuItemClicked() {
        refresh()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        setStatusTitle("5h ..%\nwk ..%")
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try self.fetcher.fetch()
                DispatchQueue.main.async {
                    self.latestSnapshot = snapshot
                    self.latestError = nil
                    self.isRefreshing = false
                    self.setStatusTitle(CodexUsageDisplayFormatter.menuTitle(for: snapshot))
                    self.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.latestError = error
                    self.isRefreshing = false
                    self.setStatusTitle(CodexUsageDisplayFormatter.errorTitle())
                    self.rebuildMenu()
                }
            }
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.title = ""
        button.imagePosition = .imageOnly
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        let image = StatusTitleImageRenderer.render(
            title,
            color: NSColor.labelColor
        )
        statusItem.length = image.size.width + 4
        button.image = image
        button.toolTip = title.replacingOccurrences(of: "\n", with: " / ")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRefreshing {
            addDisabled("Refreshing...", to: menu)
        } else if let snapshot = latestSnapshot {
            let display = CodexUsageDisplayFormatter.display(for: snapshot)
            for titleLine in display.title.split(separator: "\n") {
                addDisabled(String(titleLine), to: menu)
            }
            menu.addItem(NSMenuItem.separator())
            if let accountLine = display.accountLine {
                addDisabled(accountLine, to: menu)
            }
            addDisabled(display.currentLine, to: menu)
            addDisabled(display.weeklyLine, to: menu)
            if let creditsLine = display.creditsLine {
                addDisabled(creditsLine, to: menu)
            }
            addDisabled(display.updatedLine, to: menu)
        } else if let latestError {
            addDisabled("Codex usage unavailable", to: menu)
            addDisabled(latestError.localizedDescription, to: menu)
        } else {
            addDisabled("Codex usage not loaded", to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshMenuItemClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit CodexGlance", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

private enum StatusTitleImageRenderer {
    static func render(_ title: String, color: NSColor) -> NSImage {
        let lines = normalizedLines(from: title)
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let lineSizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let contentWidth = ceil(lineSizes.map(\.width).max() ?? 44)
        let width = max(48, contentWidth + 6)
        let height: CGFloat = 20
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        let yPositions: [CGFloat] = [10.4, 1.4]
        for (index, line) in lines.enumerated() {
            let string = line as NSString
            let lineWidth = lineSizes[index].width
            let x = floor((width - lineWidth) / 2)
            string.draw(at: NSPoint(x: x, y: yPositions[index]), withAttributes: attributes)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func normalizedLines(from title: String) -> [String] {
        let lines = title
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if lines.count >= 2 {
            return Array(lines.prefix(2))
        }

        return [lines.first ?? "", ""]
    }
}
