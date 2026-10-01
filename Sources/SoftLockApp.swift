import AppKit
import ApplicationServices
import ServiceManagement

@main
struct SoftLockMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let keepAwake = "keepAwake"
        static let keepAwakeWhileLocked = "keepAwakeWhileLocked"
        static let blurWhileLocked = "blurWhileLocked"
    }

    private let locker = InputLocker()
    private let awake = AwakeAssertion()
    private let blur = ScreenBlur()
    private let defaults = UserDefaults.standard

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let keepAwakeLockedItem = NSMenuItem(title: "Keep Awake While Locked", action: #selector(toggleKeepAwakeWhileLocked), keyEquivalent: "")
    private let blurItem = NSMenuItem(title: "Blur Screen While Locked", action: #selector(toggleBlurWhileLocked), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit SoftLock", action: #selector(quit), keyEquivalent: "q")

    private var keepAwake: Bool {
        get { defaults.bool(forKey: Key.keepAwake) }
        set { defaults.set(newValue, forKey: Key.keepAwake) }
    }

    private var keepAwakeWhileLocked: Bool {
        get { defaults.bool(forKey: Key.keepAwakeWhileLocked) }
        set { defaults.set(newValue, forKey: Key.keepAwakeWhileLocked) }
    }

    private var blurWhileLocked: Bool {
        get { defaults.bool(forKey: Key.blurWhileLocked) }
        set { defaults.set(newValue, forKey: Key.blurWhileLocked) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Key.keepAwake: false, Key.keepAwakeWhileLocked: true, Key.blurWhileLocked: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        for item in [lockItem, blurItem, keepAwakeItem, keepAwakeLockedItem, loginItem, accessibilityItem, quitItem] {
            item.target = self
        }
        menu.addItem(statusLine)
        menu.addItem(lockItem)
        menu.addItem(.separator())
        menu.addItem(blurItem)
        menu.addItem(keepAwakeItem)
        menu.addItem(keepAwakeLockedItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(quitItem)
        statusItem.menu = menu

        locker.isAllowedPoint = { [weak self] point in
            self?.statusItemContains(point) ?? false
        }
        locker.isIgnoredWindow = { [weak self] number in
            self?.blur.contains(windowNumber: number) ?? false
        }

        blur.holeRect = { [weak self] in
            self?.statusItem.button?.window?.frame
        }
        if let statusWindow = statusItem.button?.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(statusItemMoved),
                name: NSWindow.didMoveNotification,
                object: statusWindow
            )
        }

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        locker.unlock()
        blur.hide()
        awake.set(false)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleLock() {
        if locker.isLocked {
            locker.unlock()
        } else {
            lock()
        }
        refresh()
    }

    @objc private func toggleBlurWhileLocked() {
        blurWhileLocked.toggle()
        refresh()
    }

    @objc private func statusItemMoved() {
        blur.updateHole()
    }

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
        refresh()
    }

    @objc private func toggleKeepAwakeWhileLocked() {
        keepAwakeWhileLocked.toggle()
        refresh()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showAlert(
                title: "Couldn't update Open at Login",
                message: "\(error.localizedDescription)\n\nYou can add SoftLock manually in System Settings → General → Login Items."
            )
        }
        refresh()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Locking

    private func lock() {
        guard AXIsProcessTrusted() else {
            // Registers SoftLock in the Accessibility list (and may show the system prompt).
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            requestAccessibility()
            return
        }
        if !locker.lock() {
            requestAccessibility()
        }
    }

    private func requestAccessibility() {
        let open = showAlert(
            title: "SoftLock needs Accessibility access",
            message: "To block the keyboard and mouse, enable SoftLock in System Settings → Privacy & Security → Accessibility, then choose Lock again.",
            buttons: ["Open Settings", "Cancel"]
        ) == .alertFirstButtonReturn
        if open {
            openAccessibilitySettings()
        }
    }

    // MARK: - State

    private func refresh() {
        let locked = locker.isLocked

        awake.set(keepAwake || (locked && keepAwakeWhileLocked))
        if locked && blurWhileLocked {
            blur.show()
        } else {
            blur.hide()
        }

        let symbol = locked ? "lock.fill" : "lock.open"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: locked ? "SoftLock: locked" : "SoftLock: unlocked")
        image?.isTemplate = true
        statusItem.button?.image = image

        statusLine.title = locked ? "Locked — keyboard & mouse blocked" : "Unlocked"
        lockItem.title = locked ? "Unlock" : "Lock"
        blurItem.state = blurWhileLocked ? .on : .off
        keepAwakeItem.state = keepAwake ? .on : .off
        keepAwakeLockedItem.state = keepAwakeWhileLocked ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.title = AXIsProcessTrusted() ? "Accessibility Settings…" : "Allow Accessibility Access…"
        // Unlock should be the only way out while locked.
        quitItem.isEnabled = !locked
        // Settings can't be clicked while input is blocked.
        accessibilityItem.isEnabled = !locked
    }

    /// Whether `point` (global CG coordinates, top-left origin) is over the status item.
    private func statusItemContains(_ point: CGPoint) -> Bool {
        guard let frame = statusItem.button?.window?.frame,
              let primary = NSScreen.screens.first
        else { return false }
        let rect = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        return rect.contains(point)
    }

    @discardableResult
    private func showAlert(title: String, message: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }
}
