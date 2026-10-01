import AppKit

/// Darkens every screen with a click-through overlay, leaving a hole over the
/// SoftLock status item so the lock icon stays bright.
@MainActor
final class ScreenDimmer: NSObject {
    /// Area to leave undimmed, in Cocoa screen coordinates (bottom-left origin).
    var holeRect: (() -> NSRect?)?

    private(set) var isShowing = false
    private var windows: [NSWindow] = []

    // Above status items (so the menu bar is dimmed too) but below menus,
    // so SoftLock's own menu draws on top of the overlay.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func contains(windowNumber: Int) -> Bool {
        windows.contains { $0.windowNumber == windowNumber }
    }

    func show() {
        guard !isShowing else { return }
        isShowing = true
        rebuild()
        for window in windows {
            window.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            for window in windows {
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        removeWindows()
    }

    /// Re-reads `holeRect`, e.g. after the status item moves.
    func updateHole() {
        let hole = holeRect?()
        for window in windows {
            guard let view = window.contentView as? DimView else { continue }
            if let hole, window.frame.intersects(hole) {
                view.hole = hole.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            } else {
                view.hole = nil
            }
        }
    }

    @objc private func screensChanged() {
        if isShowing { rebuild() }
    }

    private func rebuild() {
        removeWindows()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = Self.level
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = DimView()
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
        updateHole()
    }

    private func removeWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

/// Fills its bounds with 50% black, except for `hole`.
private final class DimView: NSView {
    var hole: NSRect? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        let path = NSBezierPath(rect: bounds)
        if let hole {
            path.append(NSBezierPath(roundedRect: hole, xRadius: 4, yRadius: 4))
            path.windingRule = .evenOdd
        }
        path.fill()
    }
}
