import AppKit
import CodexGlanceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Defaults {
        static let showWeeklyInMenuBar = "showWeeklyInMenuBar"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher: CodexUsageFetching
    private let userDefaults: UserDefaults
    private var fetchTimer: Timer?
    private var displayTimer: Timer?
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
        updateStatusTitle()
        rebuildMenu()
        refresh()

        fetchTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fetchTimer?.invalidate()
        displayTimer?.invalidate()
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
        let now = Date()
        let lines: [CodexUsageMenuLine]
        let tooltip: String

        if let latestSnapshot {
            lines = CodexUsageDisplayFormatter.menuLines(
                for: latestSnapshot,
                includeWeekly: showWeeklyInMenuBar,
                now: now
            )
            tooltip = CodexUsageDisplayFormatter.menuTitle(
                for: latestSnapshot,
                includeWeekly: showWeeklyInMenuBar,
                now: now
            )
        } else if let latestError {
            lines = CodexUsageDisplayFormatter.menuLines(for: nil, includeWeekly: showWeeklyInMenuBar)
            tooltip = "\(CodexUsageDisplayFormatter.errorTitle(includeWeekly: showWeeklyInMenuBar)) / \(latestError.localizedDescription)"
        } else {
            lines = CodexUsageDisplayFormatter.menuLines(for: nil, includeWeekly: showWeeklyInMenuBar)
            tooltip = isRefreshing ? "Refreshing Codex usage" : "Codex usage not loaded"
        }

        let state: StatusTitleImageRenderer.State
        if isRefreshing {
            state = .refreshing
        } else if latestError != nil {
            state = .error
        } else {
            state = .normal
        }

        setStatusLines(lines, state: state, tooltip: tooltip)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.title = ""
    }

    private func setStatusLines(
        _ lines: [CodexUsageMenuLine],
        state: StatusTitleImageRenderer.State,
        tooltip: String
    ) {
        guard let button = statusItem.button else {
            return
        }

        let image = StatusTitleImageRenderer.render(
            lines,
            state: state
        )
        statusItem.length = image.size.width + 6
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = image
        button.toolTip = tooltip.replacingOccurrences(of: "\n", with: " / ")
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
    enum State: Equatable {
        case normal
        case refreshing
        case error
    }

    private struct Metrics {
        let height: CGFloat
        let rowHeight: CGFloat
        let paddingX: CGFloat
        let labelGap: CGFloat
        let barGap: CGFloat
        let valueGap: CGFloat
        let barWidth: CGFloat
        let barHeight: CGFloat
        let labelFont: NSFont
        let valueFont: NSFont
        let resetFont: NSFont

        init(lineCount: Int) {
            if lineCount == 1 {
                height = 18
                rowHeight = 18
                paddingX = 3
                labelGap = 5
                barGap = 5
                valueGap = 5
                barWidth = 56
                barHeight = 10
                labelFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                resetFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
            } else {
                height = 22
                rowHeight = 10
                paddingX = 3
                labelGap = 3
                barGap = 4
                valueGap = 4
                barWidth = 42
                barHeight = 7
                labelFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
                resetFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)
            }
        }
    }

    static func render(_ sourceLines: [CodexUsageMenuLine], state: State) -> NSImage {
        let lines = normalizedLines(sourceLines)
        let metrics = Metrics(lineCount: lines.count)
        let labelAttributes = attributes(font: metrics.labelFont, color: .labelColor)
        let valueAttributes = attributes(font: metrics.valueFont, color: .labelColor)
        let resetAttributes = attributes(font: metrics.resetFont, color: .secondaryLabelColor)

        let labelWidth = ceil(lines.map { textSize($0.label, attributes: labelAttributes).width }.max() ?? 14)
        let valueWidth = ceil(lines.map { textSize(percentText(for: $0), attributes: valueAttributes).width }.max() ?? 24)
        let resetWidth = ceil(lines.map { textSize($0.resetText ?? "", attributes: resetAttributes).width }.max() ?? 0)
        let resetGap = resetWidth > 0 ? metrics.valueGap : 0
        let contentWidth = labelWidth
            + metrics.labelGap
            + metrics.barWidth
            + metrics.barGap
            + valueWidth
            + resetGap
            + resetWidth
        let width = ceil(metrics.paddingX * 2 + contentWidth)
        let image = NSImage(size: NSSize(width: width, height: metrics.height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        for (index, line) in lines.enumerated() {
            let rowRect = rowRect(for: index, lineCount: lines.count, metrics: metrics, width: width)
            var x = metrics.paddingX

            drawText(line.label, atX: x, in: rowRect, attributes: labelAttributes)
            x += labelWidth + metrics.labelGap

            let barRect = NSRect(
                x: x,
                y: floor(rowRect.midY - metrics.barHeight / 2),
                width: metrics.barWidth,
                height: metrics.barHeight
            )
            drawUsageMeter(in: barRect, percent: line.remainingPercent, state: state)
            x += metrics.barWidth + metrics.barGap

            drawText(percentText(for: line), atX: x, in: rowRect, attributes: valueAttributes)
            x += valueWidth

            if let resetText = line.resetText, !resetText.isEmpty {
                x += metrics.valueGap
                drawText(resetText, atX: x, in: rowRect, attributes: resetAttributes)
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func normalizedLines(_ lines: [CodexUsageMenuLine]) -> [CodexUsageMenuLine] {
        let normalized = Array(lines.prefix(2))
        if normalized.isEmpty {
            return [CodexUsageMenuLine(label: "5h", remainingPercent: nil, resetText: nil)]
        }

        return normalized
    }

    private static func rowRect(
        for index: Int,
        lineCount: Int,
        metrics: Metrics,
        width: CGFloat
    ) -> NSRect {
        if lineCount == 1 {
            return NSRect(x: 0, y: 0, width: width, height: metrics.rowHeight)
        }

        let topY = metrics.height - 1 - metrics.rowHeight
        let bottomY: CGFloat = 1
        let y = index == 0 ? topY : bottomY
        return NSRect(x: 0, y: y, width: width, height: metrics.rowHeight)
    }

    private static func drawText(
        _ text: String,
        atX x: CGFloat,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: floor(x), y: floor(rect.midY - size.height / 2)),
            withAttributes: attributes
        )
    }

    private static func drawUsageMeter(in rect: NSRect, percent: Int?, state: State) {
        let radius = min(4, rect.height * 0.36)
        let borderColor = meterBorderColor(for: state)
        let shellPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        shellPath.fill()
        borderColor.setStroke()
        shellPath.lineWidth = 1.1
        shellPath.stroke()

        guard let percent else {
            drawMeterTicks(in: rect, color: borderColor)
            return
        }

        let fraction = min(1, max(0, CGFloat(percent) / 100))
        guard fraction > 0 else {
            drawMeterTicks(in: rect, color: borderColor)
            return
        }

        let innerRect = rect.insetBy(dx: 2, dy: 2)
        let innerPath = NSBezierPath(
            roundedRect: innerRect,
            xRadius: max(1, innerRect.height / 2),
            yRadius: max(1, innerRect.height / 2)
        )
        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        progressColor(for: percent, state: state).setFill()
        NSRect(
            x: innerRect.minX,
            y: innerRect.minY,
            width: innerRect.width * fraction,
            height: innerRect.height
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawMeterTicks(in: rect, color: borderColor)
    }

    private static func drawMeterTicks(in rect: NSRect, color: NSColor) {
        let innerRect = rect.insetBy(dx: 2, dy: 2)
        let tickColor = color.withAlphaComponent(0.28)
        tickColor.setStroke()

        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            let x = floor(innerRect.minX + innerRect.width * fraction) + 0.5
            let path = NSBezierPath()
            path.lineWidth = 0.8
            path.move(to: NSPoint(x: x, y: innerRect.minY + 1))
            path.line(to: NSPoint(x: x, y: innerRect.maxY - 1))
            path.stroke()
        }
    }

    private static func percentText(for line: CodexUsageMenuLine) -> String {
        line.remainingPercent.map { "\($0)%" } ?? "--%"
    }

    private static func textSize(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSSize {
        (text as NSString).size(withAttributes: attributes)
    }

    private static func attributes(
        font: NSFont,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .kern: 0
        ]
    }

    private static func progressColor(for percent: Int, state: State) -> NSColor {
        if state == .refreshing {
            return .systemBlue
        }

        if state == .error {
            return .systemRed
        }

        switch percent {
        case 60...:
            return .systemGreen
        case 30..<60:
            return .systemOrange
        default:
            return .systemRed
        }
    }

    private static func meterBorderColor(for state: State) -> NSColor {
        switch state {
        case .refreshing:
            return NSColor.systemBlue.withAlphaComponent(0.75)
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.8)
        case .normal:
            return NSColor.labelColor.withAlphaComponent(0.55)
        }
    }
}
