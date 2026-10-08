import AppKit
import CodexGlanceCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Defaults {
        static let menuBarWindows = "menuBarWindows"
        // Replaced by `menuBarWindows`; read until a new choice is saved.
        static let legacyShowWeeklyInMenuBar = "showWeeklyInMenuBar"
        static let menuBarProvider = "menuBarProvider"
    }

    private final class ProviderState {
        let provider: UsageProvider
        let monitor: UsageMonitoring
        var latestSnapshot: UsageSnapshot?
        var latestError: Error?
        var isRefreshing = false
        var lastRefreshStartedAt: Date?

        init(provider: UsageProvider, monitor: UsageMonitoring) {
            self.provider = provider
            self.monitor = monitor
        }
    }

    private static let fallbackRefreshInterval: TimeInterval = 300
    private static let displayRefreshInterval: TimeInterval = 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let providers: [ProviderState]
    private let userDefaults: UserDefaults
    private var fetchTimer: Timer?
    private var displayTimer: Timer?
    private var isCheckingForUpdates = false
    private let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var menuBarWindows: MenuBarWindows {
        get {
            if let rawValue = userDefaults.string(forKey: Defaults.menuBarWindows),
               let windows = MenuBarWindows(rawValue: rawValue) {
                return windows
            }

            return userDefaults.bool(forKey: Defaults.legacyShowWeeklyInMenuBar) ? .both : .current
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Defaults.menuBarWindows)
        }
    }

    private var menuBarProvider: ProviderState {
        // Codex unless the user switched products in "Show in Menu Bar".
        let rawValue = userDefaults.string(forKey: Defaults.menuBarProvider) ?? UsageProvider.codex.rawValue
        return providers.first { $0.provider.rawValue == rawValue } ?? providers[0]
    }

    init(
        monitors: [UsageProvider: UsageMonitoring] = [
            .codex: CodexUsageMonitor(),
            .claude: ClaudeUsageFetcher()
        ],
        userDefaults: UserDefaults = .standard
    ) {
        providers = UsageProvider.allCases.compactMap { provider in
            monitors[provider].map { ProviderState(provider: provider, monitor: $0) }
        }
        precondition(!providers.isEmpty, "At least one usage provider is required")
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
        for state in providers {
            state.monitor.shutdown()
        }
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

    @objc private func menuBarWindowsClicked(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let windows = MenuBarWindows(rawValue: rawValue) else {
            return
        }

        menuBarWindows = windows
        updateStatusTitle()
        rebuildMenu()
    }

    @objc private func menuBarProviderClicked(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else {
            return
        }

        userDefaults.set(rawValue, forKey: Defaults.menuBarProvider)
        updateStatusTitle()
        rebuildMenu()
    }

    @objc private func openWebsiteClicked() {
        NSWorkspace.shared.open(ReleaseUpdateChecker.websiteURL)
    }

    @objc private func openDownloadClicked() {
        NSWorkspace.shared.open(ReleaseUpdateChecker.releasesURL)
    }

    @objc private func checkForUpdatesClicked() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        rebuildMenu()
        ReleaseUpdateChecker.check(installedVersion: installedVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingForUpdates = false
                self.rebuildMenu()
                self.showUpdateResult(result)
            }
        }
    }

    private func showUpdateResult(_ result: Result<ReleaseUpdateStatus, Error>) {
        let alert = NSAlert()
        switch result {
        case .success(.updateAvailable(let version)):
            alert.messageText = "CodexGlance \(version) Is Available"
            alert.informativeText = "Installed version: \(installedVersion ?? "unknown"). Download the new release and replace CodexGlance in Applications."
        case .success(.noNewerRelease(let version)):
            alert.messageText = "No Newer Release"
            alert.informativeText = "Installed version: \(installedVersion ?? "unknown"). Latest published release: \(version)."
        case .success(.unknownInstalledVersion(let version)):
            alert.messageText = "Latest Release: \(version)"
            alert.informativeText = "This build has no comparable release version. Download a packaged release to enable version comparisons."
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Unable to Check for Updates"
            alert.informativeText = "\(error.localizedDescription) You can check the download page manually."
        }
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openDownloadClicked()
        }
    }

    private func refresh() {
        for state in providers {
            refresh(state)
        }
    }

    private func refresh(_ state: ProviderState) {
        guard !state.isRefreshing else {
            return
        }
        let now = Date()
        if let lastRefreshStartedAt = state.lastRefreshStartedAt,
           now.timeIntervalSince(lastRefreshStartedAt) < Self.refreshDebounceInterval(for: state.provider) {
            return
        }
        state.lastRefreshStartedAt = now

        state.isRefreshing = true
        updateStatusTitle()
        rebuildMenu()

        let monitor = state.monitor
        DispatchQueue.global(qos: .utility).async { [weak self, weak state] in
            do {
                let snapshot = try monitor.fetch()
                DispatchQueue.main.async {
                    guard let state else { return }
                    self?.handleSnapshot(snapshot, for: state)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let state else { return }
                    self?.handleError(error, for: state)
                }
            }
        }
    }

    private static func refreshDebounceInterval(for provider: UsageProvider) -> TimeInterval {
        switch provider {
        case .codex:
            return 10
        case .claude:
            // Claude usage is polled over HTTP and the endpoint throttles bursts.
            return 60
        }
    }

    private func configureUsageCallbacks() {
        for state in providers {
            state.monitor.onSnapshot = { [weak self, weak state] snapshot in
                DispatchQueue.main.async {
                    guard let state else { return }
                    self?.handleSnapshot(snapshot, for: state)
                }
            }
            state.monitor.onError = { [weak self, weak state] error in
                DispatchQueue.main.async {
                    guard let state else { return }
                    self?.handleError(error, for: state)
                }
            }
        }
    }

    private func startMonitoring() {
        for state in providers {
            state.lastRefreshStartedAt = Date()
            state.isRefreshing = true
        }
        updateStatusTitle()
        rebuildMenu()
        for state in providers {
            state.monitor.start()
        }
    }

    private func handleSnapshot(_ snapshot: UsageSnapshot, for state: ProviderState) {
        state.latestSnapshot = snapshot
        state.latestError = nil
        state.isRefreshing = false
        updateStatusTitle()
        rebuildMenu()
    }

    private func handleError(_ error: Error, for state: ProviderState) {
        state.latestError = error
        state.isRefreshing = false
        updateStatusTitle()
        rebuildMenu()
    }

    private func updateStatusTitle() {
        let now = Date()
        let state = menuBarProvider
        let name = state.provider.displayName
        let lines: [UsageMenuLine]
        let tooltip: String

        if let latestSnapshot = state.latestSnapshot {
            lines = UsageDisplayFormatter.menuLines(
                for: latestSnapshot,
                windows: menuBarWindows,
                now: now
            )
            tooltip = "\(name) · " + UsageDisplayFormatter.menuTitle(
                for: latestSnapshot,
                windows: menuBarWindows,
                now: now
            )
        } else if let latestError = state.latestError {
            lines = UsageDisplayFormatter.menuLines(for: nil, windows: menuBarWindows)
            tooltip = "\(name) · \(UsageDisplayFormatter.errorTitle()) / \(latestError.localizedDescription)"
        } else {
            lines = UsageDisplayFormatter.menuLines(for: nil, windows: menuBarWindows)
            tooltip = state.isRefreshing ? "Refreshing \(name) usage" : "\(name) usage not loaded"
        }

        let renderState: StatusTitleImageRenderer.State
        if state.isRefreshing {
            renderState = .refreshing
        } else if state.latestError != nil {
            renderState = .error
        } else {
            renderState = .normal
        }

        // The mark only matters when there is a second product to tell apart.
        let hasBothProducts = providers.filter { $0.latestSnapshot != nil }.count > 1
        setStatusLines(lines, state: renderState, mark: hasBothProducts ? state.provider : nil, tooltip: tooltip)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.title = ""
    }

    private func setStatusLines(
        _ lines: [UsageMenuLine],
        state: StatusTitleImageRenderer.State,
        mark: UsageProvider?,
        tooltip: String
    ) {
        guard let button = statusItem.button else {
            return
        }

        let image = StatusTitleImageRenderer.render(
            lines,
            state: state,
            mark: mark,
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

        let selected = menuBarProvider
        let orderedProviders = [selected] + providers.filter { $0 !== selected }
        for (index, state) in orderedProviders.enumerated() {
            if index > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            addSection(for: state, to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        let showMenu = NSMenu()
        if providers.count > 1 {
            for state in providers {
                addChoice(
                    state.provider.displayName,
                    value: state.provider.rawValue,
                    isSelected: state === selected,
                    action: #selector(menuBarProviderClicked(_:)),
                    to: showMenu
                )
            }
        }
        if let current = selected.latestSnapshot?.current, let weekly = selected.latestSnapshot?.weekly {
            if !showMenu.items.isEmpty {
                showMenu.addItem(NSMenuItem.separator())
            }
            let currentLabel = UsageDisplayFormatter.windowLabel(for: current)
            let weeklyLabel = UsageDisplayFormatter.windowLabel(for: weekly, fallback: "more")
            let choices: [(String, MenuBarWindows)] = [
                (currentLabel, .current),
                (weeklyLabel, .weekly),
                ("\(currentLabel) + \(weeklyLabel)", .both)
            ]
            for (title, windows) in choices {
                addChoice(
                    title,
                    value: windows.rawValue,
                    isSelected: windows == menuBarWindows,
                    action: #selector(menuBarWindowsClicked(_:)),
                    to: showMenu
                )
            }
        }
        if !showMenu.items.isEmpty {
            let showItem = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
            showItem.submenu = showMenu
            menu.addItem(showItem)
        }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshMenuItemClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = providers.contains { !$0.isRefreshing }
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())
        addDisabled("CodexGlance \(installedVersion ?? "(Development Build)")", to: menu)

        let updateItem = NSMenuItem(
            title: isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…",
            action: isCheckingForUpdates ? nil : #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        let websiteItem = NSMenuItem(title: "Website", action: #selector(openWebsiteClicked), keyEquivalent: "")
        websiteItem.target = self
        menu.addItem(websiteItem)

        let downloadItem = NSMenuItem(title: "Download Latest Version", action: #selector(openDownloadClicked), keyEquivalent: "")
        downloadItem.target = self
        menu.addItem(downloadItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit CodexGlance", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addSection(for state: ProviderState, to menu: NSMenu) {
        let name = state.provider.displayName
        addHeader(name, to: menu)

        if let snapshot = state.latestSnapshot {
            let display = UsageDisplayFormatter.display(for: snapshot)
            if let accountLine = display.accountLine {
                addDisabled(accountLine, to: menu)
            }
            for usageLine in display.usageLines {
                addDisabled(usageLine, to: menu)
            }
            for additionalLimitLine in display.additionalLimitLines {
                addDisabled(additionalLimitLine, to: menu)
            }
            if let resetCreditsLine = display.resetCreditsLine {
                addDisabled(resetCreditsLine, to: menu)
            }
            if let creditsLine = display.creditsLine {
                addDisabled(creditsLine, to: menu)
            }
            if let latestError = state.latestError {
                addDisabled("Refresh failed: \(latestError.localizedDescription)", to: menu)
            }
            addDisabled(state.isRefreshing ? "Refreshing..." : display.updatedLine, to: menu)
        } else if state.isRefreshing {
            addDisabled("Refreshing...", to: menu)
        } else if let latestError = state.latestError {
            addDisabled("\(name) usage unavailable", to: menu)
            addDisabled(latestError.localizedDescription, to: menu)
        } else {
            addDisabled("\(name) usage not loaded", to: menu)
        }
    }

    private func addChoice(_ title: String, value: String, isSelected: Bool, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = isSelected ? .on : .off
        menu.addItem(item)
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        item.isEnabled = false
        menu.addItem(item)
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
        let markSize: CGFloat
        let markGap: CGFloat
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
                markSize = 11
                markGap = 4
                labelFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            } else {
                height = 22
                rowHeight = 10
                paddingX = 3
                labelGap = 3
                gaugeGap = 4
                gaugeSize = 9
                markSize = 12
                markGap = 4
                labelFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
                valueFont = NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold)
            }
        }
    }

    static func render(
        _ sourceLines: [UsageMenuLine],
        state: State,
        mark: UsageProvider?,
        appearance: NSAppearance
    ) -> NSImage {
        let lines = normalizedLines(sourceLines)
        let metrics = Metrics(lineCount: lines.count)
        let labelAttributes = attributes(font: metrics.labelFont, color: .labelColor)
        let valueAttributes = attributes(font: metrics.valueFont, color: .labelColor)

        let labelWidth = ceil(lines.map { textSize($0.label, attributes: labelAttributes).width }.max() ?? 14)
        let valueWidth = ceil(lines.map { textSize(percentText(for: $0), attributes: valueAttributes).width }.max() ?? 24)
        let markWidth = mark == nil ? 0 : metrics.markSize + metrics.markGap
        let contentWidth = markWidth
            + labelWidth
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

            if let mark {
                let markRect = NSRect(
                    x: metrics.paddingX,
                    y: floor((metrics.height - metrics.markSize) / 2),
                    width: metrics.markSize,
                    height: metrics.markSize
                )
                switch mark {
                case .codex:
                    drawCodexMark(in: markRect)
                case .claude:
                    drawClaudeMark(in: markRect)
                }
            }

            for (index, line) in lines.enumerated() {
                let rowRect = rowRect(for: index, lineCount: lines.count, metrics: metrics, width: width)
                var x = metrics.paddingX + markWidth

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

    private static func normalizedLines(_ lines: [UsageMenuLine]) -> [UsageMenuLine] {
        let normalized = Array(lines.prefix(2))
        if normalized.isEmpty {
            return [UsageMenuLine(label: "use", remainingPercent: nil, resetText: nil)]
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
        for line: UsageMenuLine,
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

    // A terminal prompt, `>_`, in the label color so it follows light and dark mode.
    private static func drawCodexMark(in rect: NSRect) {
        let prompt = NSBezierPath()
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.lineWidth = max(1.3, rect.width * 0.14)
        prompt.move(to: NSPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.80))
        prompt.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.midY))
        prompt.line(to: NSPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.20))
        prompt.move(to: NSPoint(x: rect.minX + rect.width * 0.56, y: rect.minY + rect.height * 0.20))
        prompt.line(to: NSPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.20))
        NSColor.labelColor.setStroke()
        prompt.stroke()
    }

    private static func drawClaudeMark(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let spark = NSBezierPath()
        spark.lineCapStyle = .round
        spark.lineWidth = max(1.2, rect.width * 0.15)
        for index in 0..<8 {
            let angle = CGFloat(index) * 45 + 22.5
            spark.move(to: point(from: center, radius: rect.width * 0.12, angleDegrees: angle))
            spark.line(to: point(from: center, radius: rect.width * 0.46, angleDegrees: angle))
        }
        claudeMarkColor.setStroke()
        spark.stroke()
    }

    private static let claudeMarkColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    private static func percentText(for line: UsageMenuLine) -> String {
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
