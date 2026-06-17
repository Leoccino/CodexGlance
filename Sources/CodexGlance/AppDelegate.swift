import AppKit
import CodexGlanceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Defaults {
        static let showWeeklyInMenuBar = "showWeeklyInMenuBar"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher: CodexUsageFetching
    private let userDefaults: UserDefaults
    private var timer: Timer?
    private var latestSnapshot: CodexUsageSnapshot?
    private var latestError: Error?
    private var isRefreshing = false
    private var showWeeklyInMenuBar: Bool {
        get {
            if userDefaults.object(forKey: Defaults.showWeeklyInMenuBar) == nil {
                return false
            }

            return userDefaults.bool(forKey: Defaults.showWeeklyInMenuBar)
        }
        set {
            userDefaults.set(newValue, forKey: Defaults.showWeeklyInMenuBar)
        }
    }

    init(fetcher: CodexUsageFetching = CodexUsageFetcher(), userDefaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.userDefaults = userDefaults
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusButton()
        setStatusTitle(CodexUsageDisplayFormatter.menuTitle(for: nil, includeWeekly: showWeeklyInMenuBar))
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

    @objc private func toggleWeeklyClicked() {
        showWeeklyInMenuBar.toggle()
        updateStatusTitle()
        rebuildMenu()
    }

    private func refresh() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        updateStatusTitle()
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try self.fetcher.fetch()
                DispatchQueue.main.async {
                    self.latestSnapshot = snapshot
                    self.latestError = nil
                    self.isRefreshing = false
                    self.updateStatusTitle()
                    self.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.latestError = error
                    self.isRefreshing = false
                    self.updateStatusTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func updateStatusTitle() {
        let title: String
        if isRefreshing {
            title = showWeeklyInMenuBar ? "5h ..%\nwk ..%" : "5h ..%"
        } else if let latestSnapshot {
            title = CodexUsageDisplayFormatter.menuTitle(for: latestSnapshot, includeWeekly: showWeeklyInMenuBar)
        } else if latestError != nil {
            title = CodexUsageDisplayFormatter.errorTitle(includeWeekly: showWeeklyInMenuBar)
        } else {
            title = CodexUsageDisplayFormatter.menuTitle(for: nil, includeWeekly: showWeeklyInMenuBar)
        }

        setStatusTitle(title)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.title = ""
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        if !title.contains("\n") {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            button.title = title
            button.toolTip = title
            return
        }

        let image = StatusTitleImageRenderer.render(
            title,
            color: NSColor.labelColor
        )
        statusItem.length = image.size.width + 4
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = image
        button.toolTip = title.replacingOccurrences(of: "\n", with: " / ")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRefreshing {
            addDisabled("Refreshing...", to: menu)
        } else if let snapshot = latestSnapshot {
            let display = CodexUsageDisplayFormatter.display(for: snapshot, includeWeekly: showWeeklyInMenuBar)
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
        let weeklyItem = NSMenuItem(title: "Show Weekly in Menu Bar", action: #selector(toggleWeeklyClicked), keyEquivalent: "")
        weeklyItem.target = self
        weeklyItem.state = showWeeklyInMenuBar ? .on : .off
        menu.addItem(weeklyItem)

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
        let fontSize: CGFloat = lines.count == 1 ? 12.5 : 9.5
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let lineSizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let contentWidth = ceil(lineSizes.map(\.width).max() ?? 44)
        let width = max(56, contentWidth + 8)
        let height: CGFloat = 23
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        let lineHeight = ceil(font.boundingRectForFont.height)
        let lineGap: CGFloat = -1
        let lineCount = CGFloat(lines.count)
        let totalTextHeight = lineHeight * lineCount + lineGap * max(0, lineCount - 1)
        let bottomY = floor((height - totalTextHeight) / 2)
        let yPositions = (0..<lines.count).map { index in
            bottomY + CGFloat(lines.count - index - 1) * (lineHeight + lineGap)
        }
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

        if lines.isEmpty {
            return [""]
        }

        return Array(lines.prefix(2))
    }
}
