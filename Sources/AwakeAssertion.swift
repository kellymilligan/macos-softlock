import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that keeps the display (and therefore the
/// system) from idle-sleeping, like `caffeinate -d`.
final class AwakeAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func set(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SoftLock is keeping this Mac awake" as CFString,
                &assertionID
            )
            isActive = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }
}
