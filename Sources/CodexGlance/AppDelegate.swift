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

        statusItem.button?.title = CodexUsageDisplayFormatter.menuTitle(for: nil)
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
        statusItem.button?.title = "C.. W.."
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try self.fetcher.fetch()
                DispatchQueue.main.async {
                    self.latestSnapshot = snapshot
                    self.latestError = nil
                    self.isRefreshing = false
                    self.statusItem.button?.title = CodexUsageDisplayFormatter.menuTitle(for: snapshot)
                    self.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.latestError = error
                    self.isRefreshing = false
                    self.statusItem.button?.title = CodexUsageDisplayFormatter.errorTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRefreshing {
            addDisabled("Refreshing...", to: menu)
        } else if let snapshot = latestSnapshot {
            let display = CodexUsageDisplayFormatter.display(for: snapshot)
            addDisabled(display.title, to: menu)
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
