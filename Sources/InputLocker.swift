import AppKit
import CoreGraphics

/// Swallows keyboard, click, scroll and gesture events system-wide using a
/// CGEvent tap. Pointer events that land on one of SoftLock's own windows
/// (the status item and its menu) are let through so the user can unlock.
///
/// Requires the Accessibility permission. This is a "soft" lock: it is meant to
/// stop accidental input, not to secure the machine.
@MainActor
final class InputLocker {
    private(set) var isLocked = false

    /// Extra hit-test for points (in global CG coordinates, top-left origin) that
    /// should always receive pointer events, e.g. the status item button.
    var isAllowedPoint: ((CGPoint) -> Bool)?

    /// SoftLock windows that must not let clicks through, e.g. the dimming
    /// overlay, which sits under every point on screen.
    var isIgnoredWindow: ((Int) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Raw CGEventType / NSEvent.EventType values.
    private static let keyboardTypes: Set<UInt32> = [
        10, // keyDown
        11, // keyUp
        12, // flagsChanged
        14, // NX_SYSDEFINED (media, volume, brightness keys)
    ]
    private static let pointerTypes: Set<UInt32> = [
        1, 2,       // left mouse down / up
        3, 4,       // right mouse down / up
        6, 7,       // left / right mouse dragged
        22,         // scroll wheel
        25, 26, 27, // other mouse down / up / dragged
        18, 19, 20, // rotate, begin / end gesture
        29, 30, 31, // gesture, magnify, swipe
        32, 34,     // smart magnify, pressure
    ]

    private static var eventMask: CGEventMask {
        keyboardTypes.union(pointerTypes).reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type))
        }
    }

    /// Starts blocking input. Returns false if the event tap could not be
    /// created (almost always a missing Accessibility permission).
    func lock() -> Bool {
        if isLocked { return true }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: softLockTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Common modes so the tap keeps running while our menu is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isLocked = true
        return true
    }

    func unlock() {
        guard isLocked else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isLocked = false
    }

    /// Decides whether an event should be delivered. Called from the tap callback.
    fileprivate func shouldPass(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disables taps that are slow or interrupted; turn it back on.
            if isLocked, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard isLocked else { return true }

        let raw = type.rawValue
        if Self.keyboardTypes.contains(raw) {
            if raw == 14 {
                // Only block system-defined events for the aux control buttons
                // (subtype 8: media/volume/brightness). Other subtypes accompany
                // ordinary mouse clicks.
                return NSEvent(cgEvent: event)?.subtype.rawValue != 8
            }
            return false
        }
        if Self.pointerTypes.contains(raw) {
            let point = event.location
            return isAllowedPoint?(point) == true || isOwnWindow(at: point)
        }
        return true
    }

    /// True if the frontmost window under `point` (global CG coordinates)
    /// belongs to this process, e.g. the status item or its open menu.
    private func isOwnWindow(at point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let cocoaPoint = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        let number = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        guard number > 0,
              isIgnoredWindow?(number) != true,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? Int
        else { return false }
        return pid == Int(ProcessInfo.processInfo.processIdentifier)
    }
}

private func softLockTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    // The tap's run loop source is on the main run loop.
    let pass = MainActor.assumeIsolated {
        Unmanaged<InputLocker>.fromOpaque(refcon).takeUnretainedValue()
            .shouldPass(type: type, event: event)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
