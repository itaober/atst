import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

final class GlobalHotKeyMonitor {
    struct Binding {
        let id: String
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    private(set) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [Binding] = []
    private var isStarted = false
    private var hasLoggedFirstKeyDown = false

    func update(bindings: [Binding]) {
        self.bindings = bindings
        AppLogger.log("CGEventTap bindings updated count=\(bindings.count) \(bindings.map { "\($0.id):kc=\($0.keyCode),mod=\($0.modifiers)" }.joined(separator: " | "))")
    }

    @discardableResult
    func start() -> Bool {
        if isStarted, eventTap != nil {
            return true
        }
        stop()

        guard PermissionChecker.isAccessibilityTrusted else {
            AppLogger.log("CGEventTap not started: accessibility permission missing")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: globalHotKeyTapCallback,
            userInfo: selfPointer
        ) else {
            AppLogger.log("CGEventTap creation failed (likely missing accessibility permission)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isStarted = true
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        // SecureEventInput captures the whole system's keyboard at a layer
        // below CGEventTap: when ANY app turns it on (Terminal "Secure
        // Keyboard Entry", iTerm2, 1Password autofill, password fields…)
        // every session-level event tap stops receiving keyDown events
        // globally, while flagsChanged still come through. This is the
        // single most common cause of "atst hotkey silently broken" on
        // a machine where Accessibility is granted and the tap is up.
        let secure = IsSecureEventInputEnabled()
        AppLogger.log("CGEventTap started enabled=\(enabled) ax=\(PermissionChecker.isAccessibilityTrusted) secureInput=\(secure)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isStarted = false
    }

    func reenableIfNeeded() {
        guard let tap = eventTap else {
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            AppLogger.log("CGEventTap was disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLogger.log("CGEventTap disabled by system type=\(type.rawValue), re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = GlobalHotKeyMonitor.carbonModifiers(from: event.flags)

        if !hasLoggedFirstKeyDown {
            hasLoggedFirstKeyDown = true
            AppLogger.log("CGEventTap first keyDown observed keyCode=\(keyCode) modifiers=\(modifiers)")
        }

        for binding in bindings where binding.keyCode == keyCode && binding.modifiers == modifiers {
            AppLogger.log("CGEventTap hotkey fired id=\(binding.id) keyCode=\(keyCode) modifiers=\(modifiers)")
            DispatchQueue.main.async {
                binding.action()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.maskAlternate) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.maskControl) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.maskShift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }
}

private func globalHotKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
