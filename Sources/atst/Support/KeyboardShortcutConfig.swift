import AppKit
import Carbon

struct KeyboardShortcutConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayName: String

    static let defaultText = KeyboardShortcutConfig(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(optionKey),
        displayName: "⌥D"
    )

    static let defaultScreenshot = KeyboardShortcutConfig(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(optionKey),
        displayName: "⌥S"
    )

    init(keyCode: UInt32, modifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
    }

    init?(event: NSEvent) {
        let modifiers = KeyboardShortcutConfig.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        let key = KeyboardShortcutConfig.keyName(for: keyCode, fallback: event.charactersIgnoringModifiers)
        guard !key.isEmpty else {
            return nil
        }

        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = KeyboardShortcutConfig.displayName(key: key, modifiers: modifiers)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    static func displayName(key: String, modifiers: UInt32) -> String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 {
            prefix += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            prefix += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            prefix += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            prefix += "⌘"
        }
        return prefix + key.uppercased()
    }

    static func keyName(for keyCode: UInt32, fallback: String? = nil) -> String {
        if let mapped = keyNameMap[keyCode] {
            return mapped
        }

        if let fallback, !fallback.isEmpty {
            return fallback.uppercased()
        }

        return ""
    }

    private static let keyNameMap: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab"
    ]
}
