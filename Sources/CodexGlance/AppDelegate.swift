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
    enum State {
        case normal
        case refreshing
        case error
    }

    private struct Metrics {
        let height: CGFloat
        let rowHeight: CGFloat
        let paddingX: CGFloat
        let petSize: CGFloat
        let petGap: CGFloat
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
                petSize = 14
                petGap = 5
                labelGap = 4
                barGap = 5
                valueGap = 5
                barWidth = 46
                barHeight = 7
                labelFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                resetFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
            } else {
                height = 22
                rowHeight = 10
                paddingX = 3
                petSize = 13
                petGap = 4
                labelGap = 3
                barGap = 4
                valueGap = 4
                barWidth = 34
                barHeight = 5
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
        let width = ceil(metrics.paddingX * 2 + metrics.petSize + metrics.petGap + contentWidth)
        let image = NSImage(size: NSSize(width: width, height: metrics.height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        let currentPercent = lines.first?.remainingPercent
        let petColor = petColor(for: currentPercent, state: state)
        let mood = petMood(for: currentPercent, state: state)
        let petRect = NSRect(
            x: metrics.paddingX,
            y: floor((metrics.height - metrics.petSize) / 2),
            width: metrics.petSize,
            height: metrics.petSize
        )
        drawPet(in: petRect, color: petColor, mood: mood)

        for (index, line) in lines.enumerated() {
            let rowRect = rowRect(for: index, lineCount: lines.count, metrics: metrics, width: width)
            var x = metrics.paddingX + metrics.petSize + metrics.petGap

            drawText(line.label, atX: x, in: rowRect, attributes: labelAttributes)
            x += labelWidth + metrics.labelGap

            let barRect = NSRect(
                x: x,
                y: floor(rowRect.midY - metrics.barHeight / 2),
                width: metrics.barWidth,
                height: metrics.barHeight
            )
            drawBar(in: barRect, percent: line.remainingPercent)
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

    private static func drawBar(in rect: NSRect, percent: Int?) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        track.fill()

        guard let percent else {
            return
        }

        let fraction = min(1, max(0, CGFloat(percent) / 100))
        guard fraction > 0 else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        progressColor(for: percent).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPet(in rect: NSRect, color: NSColor, mood: PetMood) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.38, yRadius: rect.height * 0.38).fill()

        color.blended(withFraction: 0.18, of: .white)?.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX + rect.width * 0.56,
                y: rect.minY + rect.height * 0.66,
                width: rect.width * 0.24,
                height: rect.height * 0.14
            ),
            xRadius: rect.height * 0.06,
            yRadius: rect.height * 0.06
        ).fill()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        NSColor.white.withAlphaComponent(0.95).setFill()

        switch mood {
        case .normal, .warning, .loading:
            drawEye(center: NSPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.58), in: rect)
            drawEye(center: NSPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.58), in: rect)
        case .low:
            drawEye(center: NSPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.58), in: rect)
            drawEye(center: NSPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.58), in: rect)
        case .error:
            drawXEye(center: NSPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.58), in: rect)
            drawXEye(center: NSPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.58), in: rect)
        }

        let mouth = NSBezierPath()
        mouth.lineWidth = max(1, rect.width * 0.08)
        switch mood {
        case .normal, .loading:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.36))
            mouth.curve(
                to: NSPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.36),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.22),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.57, y: rect.minY + rect.height * 0.22)
            )
        case .warning:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.34))
            mouth.line(to: NSPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.34))
        case .low, .error:
            mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.34))
            mouth.line(to: NSPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.34))
        }
        mouth.stroke()
    }

    private static func drawEye(center: NSPoint, in rect: NSRect) {
        let size = max(1.7, rect.width * 0.13)
        NSBezierPath(
            ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        ).fill()
    }

    private static func drawXEye(center: NSPoint, in rect: NSRect) {
        let size = max(2, rect.width * 0.14)
        let path = NSBezierPath()
        path.lineWidth = max(0.8, rect.width * 0.06)
        path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size / 2))
        path.line(to: NSPoint(x: center.x + size / 2, y: center.y + size / 2))
        path.move(to: NSPoint(x: center.x - size / 2, y: center.y + size / 2))
        path.line(to: NSPoint(x: center.x + size / 2, y: center.y - size / 2))
        path.stroke()
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

    private static func progressColor(for percent: Int) -> NSColor {
        switch percent {
        case 60...:
            return .systemGreen
        case 30..<60:
            return .systemOrange
        default:
            return .systemRed
        }
    }

    private static func petColor(for percent: Int?, state: State) -> NSColor {
        switch state {
        case .refreshing:
            return .systemBlue
        case .error:
            return .systemRed
        case .normal:
            guard let percent else {
                return .systemGray
            }

            return progressColor(for: percent)
        }
    }

    private enum PetMood {
        case normal
        case warning
        case low
        case loading
        case error
    }

    private static func petMood(for percent: Int?, state: State) -> PetMood {
        switch state {
        case .refreshing:
            return .loading
        case .error:
            return .error
        case .normal:
            guard let percent else {
                return .warning
            }

            if percent < 25 {
                return .low
            }

            if percent < 60 {
                return .warning
            }

            return .normal
        }
    }
}
