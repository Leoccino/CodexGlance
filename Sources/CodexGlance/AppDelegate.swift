import AppKit
import CodexGlanceCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Defaults {
        static let showWeeklyInMenuBar = "showWeeklyInMenuBar"
    }

    private static let fallbackRefreshInterval: TimeInterval = 300
    private static let displayRefreshInterval: TimeInterval = 60
    private static let refreshDebounceInterval: TimeInterval = 10

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher: CodexUsageMonitoring
    private let userDefaults: UserDefaults
    private var fetchTimer: Timer?
    private var displayTimer: Timer?
    private var latestSnapshot: CodexUsageSnapshot?
    private var latestError: Error?
    private var isRefreshing = false
    private var lastRefreshStartedAt: Date?
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

    init(fetcher: CodexUsageMonitoring = CodexUsageMonitor(), userDefaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.userDefaults = userDefaults
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusButton()
        configureUsageCallbacks()
        updateStatusTitle()
        rebuildMenu()
        startMonitoring()

        fetchTimer = Timer.scheduledTimer(withTimeInterval: Self.fallbackRefreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: Self.displayRefreshInterval, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fetchTimer?.invalidate()
        displayTimer?.invalidate()
        fetcher.shutdown()
    }

    @objc private func refreshMenuItemClicked() {
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
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
        let now = Date()
        if let lastRefreshStartedAt, now.timeIntervalSince(lastRefreshStartedAt) < Self.refreshDebounceInterval {
            return
        }
        lastRefreshStartedAt = now

        isRefreshing = true
        updateStatusTitle()
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try self.fetcher.fetch()
                DispatchQueue.main.async {
                    self.handleSnapshot(snapshot)
                }
            } catch {
                DispatchQueue.main.async {
                    self.handleError(error)
                }
            }
        }
    }

    private func configureUsageCallbacks() {
        fetcher.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.handleSnapshot(snapshot)
            }
        }
        fetcher.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleError(error)
            }
        }
    }

    private func startMonitoring() {
        lastRefreshStartedAt = Date()
        isRefreshing = true
        updateStatusTitle()
        rebuildMenu()
        fetcher.start()
    }

    private func handleSnapshot(_ snapshot: CodexUsageSnapshot) {
        latestSnapshot = snapshot
        latestError = nil
        isRefreshing = false
        updateStatusTitle()
        rebuildMenu()
    }

    private func handleError(_ error: Error) {
        latestError = error
        isRefreshing = false
        updateStatusTitle()
        rebuildMenu()
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
            state: state,
            appearance: button.effectiveAppearance
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
        menu.delegate = self

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
        let gaugeGap: CGFloat
        let gaugeSize: CGFloat
        let labelFont: NSFont
        let valueFont: NSFont

        init(lineCount: Int) {
            if lineCount == 1 {
                height = 18
                rowHeight = 18
                paddingX = 3
                labelGap = 5
                gaugeGap = 5
                gaugeSize = 15
                labelFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            } else {
                height = 22
                rowHeight = 10
                paddingX = 3
                labelGap = 3
                gaugeGap = 4
                gaugeSize = 9
                labelFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
            }
        }
    }

    static func render(
        _ sourceLines: [CodexUsageMenuLine],
        state: State,
        appearance: NSAppearance
    ) -> NSImage {
        let lines = normalizedLines(sourceLines)
        let metrics = Metrics(lineCount: lines.count)
        let labelAttributes = attributes(font: metrics.labelFont, color: .labelColor)
        let valueAttributes = attributes(font: metrics.valueFont, color: .labelColor)

        let labelWidth = ceil(lines.map { textSize($0.label, attributes: labelAttributes).width }.max() ?? 14)
        let valueWidth = ceil(lines.map { textSize(percentText(for: $0), attributes: valueAttributes).width }.max() ?? 24)
        let contentWidth = labelWidth
            + metrics.labelGap
            + metrics.gaugeSize
            + metrics.gaugeGap
            + valueWidth
        let width = ceil(metrics.paddingX * 2 + contentWidth)
        let image = NSImage(size: NSSize(width: width, height: metrics.height))

        image.lockFocus()
        defer { image.unlockFocus() }

        appearance.performAsCurrentDrawingAppearance {
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: image.size).fill()

            for (index, line) in lines.enumerated() {
                let rowRect = rowRect(for: index, lineCount: lines.count, metrics: metrics, width: width)
                var x = metrics.paddingX

                drawText(line.label, atX: x, in: rowRect, attributes: labelAttributes)
                drawResetUnderline(
                    for: line,
                    atX: x,
                    width: labelWidth,
                    in: rowRect,
                    state: state
                )
                x += labelWidth + metrics.labelGap

                let gaugeRect = NSRect(
                    x: x,
                    y: floor(rowRect.midY - metrics.gaugeSize / 2),
                    width: metrics.gaugeSize,
                    height: metrics.gaugeSize
                )
                drawGauge(in: gaugeRect, percent: line.remainingPercent, state: state)
                x += metrics.gaugeSize + metrics.gaugeGap

                drawText(percentText(for: line), atX: x, in: rowRect, attributes: valueAttributes)
            }
        }

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

    private static func drawResetUnderline(
        for line: CodexUsageMenuLine,
        atX x: CGFloat,
        width: CGFloat,
        in rect: NSRect,
        state: State
    ) {
        guard state != .error, let fraction = line.resetTimeFractionRemaining else {
            return
        }

        let clampedFraction = min(1, max(0, CGFloat(fraction)))
        let isCompact = rect.height <= 10
        let lineHeight: CGFloat = isCompact ? 1.35 : 2.8
        let y = isCompact ? rect.minY + 0.25 : rect.minY + 0.55
        let trackRect = NSRect(
            x: floor(x),
            y: y,
            width: max(2, floor(width)),
            height: lineHeight
        )

        let track = NSBezierPath(
            roundedRect: trackRect,
            xRadius: lineHeight / 2,
            yRadius: lineHeight / 2
        )
        NSColor.labelColor.withAlphaComponent(isCompact ? 0.24 : 0.30).setFill()
        track.fill()

        guard clampedFraction > 0 else {
            return
        }

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(lineHeight, trackRect.width * clampedFraction),
            height: trackRect.height
        )
        let fill = NSBezierPath(
            roundedRect: fillRect,
            xRadius: lineHeight / 2,
            yRadius: lineHeight / 2
        )
        resetUnderlineColor(for: clampedFraction, state: state).setFill()
        fill.fill()
    }

    private static func drawGauge(in rect: NSRect, percent: Int?, state: State) {
        let center = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.48)
        let radius = rect.width * 0.42
        let startAngle: CGFloat = 210
        let sweep: CGFloat = 240
        let endAngle = startAngle - sweep
        let lineWidth = max(1.4, rect.width * 0.16)
        let fraction = min(1, max(0, CGFloat(percent ?? 0) / 100))

        let track = NSBezierPath()
        track.lineCapStyle = .round
        track.lineWidth = lineWidth
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        track.stroke()

        if state == .error {
            drawGaugeArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                lineWidth: lineWidth,
                color: NSColor.systemRed.withAlphaComponent(0.58)
            )
        } else {
            drawGaugeZones(
                center: center,
                radius: radius,
                startAngle: startAngle,
                sweep: sweep,
                lineWidth: lineWidth
            )
        }

        guard let percent else {
            return
        }

        let needleAngle = startAngle - sweep * fraction
        let needleEnd = point(
            from: center,
            radius: radius * 0.68,
            angleDegrees: needleAngle
        )
        let needle = NSBezierPath()
        needle.lineCapStyle = .round
        needle.lineWidth = max(0.8, rect.width * 0.07)
        needle.move(to: center)
        needle.line(to: needleEnd)
        progressColor(for: percent, state: state).setStroke()
        needle.stroke()

        let dotSize = max(2, rect.width * 0.18)
        progressColor(for: percent, state: state).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - dotSize / 2,
                y: center.y - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
        ).fill()
    }

    private static func drawGaugeZones(
        center: NSPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        sweep: CGFloat,
        lineWidth: CGFloat
    ) {
        drawGaugeArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle - sweep * 0.30,
            lineWidth: lineWidth,
            color: NSColor.systemRed.withAlphaComponent(0.46)
        )
        drawGaugeArc(
            center: center,
            radius: radius,
            startAngle: startAngle - sweep * 0.30,
            endAngle: startAngle - sweep * 0.60,
            lineWidth: lineWidth,
            color: NSColor.systemOrange.withAlphaComponent(0.50)
        )
        drawGaugeArc(
            center: center,
            radius: radius,
            startAngle: startAngle - sweep * 0.60,
            endAngle: startAngle - sweep,
            lineWidth: lineWidth,
            color: NSColor.systemGreen.withAlphaComponent(0.52)
        )
    }

    private static func drawGaugeArc(
        center: NSPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        lineWidth: CGFloat,
        color: NSColor
    ) {
        let arc = NSBezierPath()
        arc.lineCapStyle = .round
        arc.lineWidth = lineWidth
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        color.setStroke()
        arc.stroke()
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

    private static func resetUnderlineColor(for fraction: CGFloat, state: State) -> NSColor {
        switch state {
        case .error:
            return .systemRed
        case .normal, .refreshing:
            if fraction <= 0.15 {
                return NSColor.systemBlue.withAlphaComponent(0.95)
            }

            if fraction <= 0.35 {
                return NSColor.systemBlue.withAlphaComponent(0.84)
            }

            if fraction <= 0.60 {
                return NSColor.systemCyan.withAlphaComponent(0.68)
            }

            return NSColor.systemCyan.withAlphaComponent(0.52)
        }
    }

    private static func progressColor(for percent: Int, state: State) -> NSColor {
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

    private static func point(
        from center: NSPoint,
        radius: CGFloat,
        angleDegrees: CGFloat
    ) -> NSPoint {
        let radians = angleDegrees * .pi / 180
        return NSPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }
}
