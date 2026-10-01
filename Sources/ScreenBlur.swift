import AppKit

/// Blurs every screen with click-through overlay windows, leaving the SoftLock
/// status item uncovered so the lock icon stays sharp.
///
/// The blur radius is set with the private `CGSSetWindowBackgroundBlurRadius`
/// call (the same one iTerm2 uses), looked up at runtime so a future macOS
/// without it can't stop the app launching. If it's missing or fails, the
/// overlay falls back to a public `NSVisualEffectView`, which blurs at a fixed,
/// stronger amount.
@MainActor
final class ScreenBlur: NSObject {
    /// Blur radius in points.
    static let radius = 12

    /// Area to leave uncovered, in Cocoa screen coordinates (bottom-left origin).
    var holeRect: (() -> NSRect?)?

    private(set) var isShowing = false
    private var windows: [NSWindow] = []

    // Above status items (so the menu bar is blurred too) but below menus,
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
        if isShowing { rebuild() }
    }

    @objc private func screensChanged() {
        if isShowing { rebuild() }
    }

    /// A window can only blur a rectangle, so each screen is tiled with up to
    /// four windows around the hole.
    private func rebuild() {
        removeWindows()
        let hole = holeRect?()
        for screen in NSScreen.screens {
            for frame in Self.tiles(covering: screen.frame, around: hole) {
                windows.append(makeWindow(frame: frame))
            }
        }
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        // Not fully clear, so the window server has something to blur behind.
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = Self.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        if !PrivateBlur.apply(radius: Self.radius, to: window) {
            let effect = NSVisualEffectView()
            effect.material = .fullScreenUI
            effect.blendingMode = .behindWindow
            effect.state = .active
            window.contentView = effect
        }
        return window
    }

    private func removeWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    /// Rectangles that together cover `rect` minus `hole`.
    private static func tiles(covering rect: NSRect, around hole: NSRect?) -> [NSRect] {
        guard let hole else { return [rect] }
        let h = rect.intersection(hole)
        guard !h.isEmpty else { return [rect] }
        return [
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: h.minY - rect.minY), // below
            NSRect(x: rect.minX, y: h.maxY, width: rect.width, height: rect.maxY - h.maxY),    // above
            NSRect(x: rect.minX, y: h.minY, width: h.minX - rect.minX, height: h.height),      // left
            NSRect(x: h.maxX, y: h.minY, width: rect.maxX - h.maxX, height: h.height),         // right
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Runtime lookup of the private window-server blur call.
private enum PrivateBlur {
    // Arguments are passed as 64-bit ints so they're correct whether the
    // callee reads them as 32- or 64-bit.
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int, Int, Int) -> Int32

    private static let mainConnectionID: MainConnectionID? = symbol("CGSMainConnectionID")
    private static let setBlurRadius: SetBlurRadius? = symbol("CGSSetWindowBackgroundBlurRadius")

    /// Returns false if the call is unavailable or the window server refused it.
    static func apply(radius: Int, to window: NSWindow) -> Bool {
        guard let mainConnectionID, let setBlurRadius, window.windowNumber > 0 else { return false }
        return setBlurRadius(Int(mainConnectionID()), window.windowNumber, radius) == 0
    }

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT: search every loaded image (the symbols live in SkyLight).
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
