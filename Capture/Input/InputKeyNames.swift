import Foundation

/// Virtual key code → name, for shortcut spelling only.
///
/// This is a physical-key (ANSI layout) table keyed by hardware key code. It never inspects the
/// character a key produces, so it cannot leak typed text; the trade-off is that on non-ANSI
/// layouts some letter/punctuation names describe the ANSI key position rather than the printed
/// legend.
enum InputKeyNames {

    /// Keys that carry no character content. They are logged as individual `shortcut` events (e.g.
    /// `return`, `shift+tab`, `down`) instead of being counted as typing.
    static let specialKeyCodes: Set<UInt16> = [
        36, 76,                       // return, keypad enter
        48,                           // tab
        51, 117,                      // delete (backspace), forward delete
        53,                           // escape
        115, 119, 116, 121,           // home, end, page up, page down
        123, 124, 125, 126,           // left, right, down, up
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90                       // F13-F20
    ]

    static func isSpecial(_ keyCode: UInt16) -> Bool {
        specialKeyCodes.contains(keyCode)
    }

    static func name(for keyCode: UInt16) -> String {
        table[keyCode] ?? "key\(keyCode)"
    }

    /// `cmd+shift+t`: modifiers in canonical order, then the key name.
    static func combo(keyCode: UInt16, modifiers: InputModifiers) -> String {
        (modifiers.names + [name(for: keyCode)]).joined(separator: "+")
    }

    private static let table: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        36: "return", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "n", 46: "m", 47: ".", 48: "tab", 49: "space", 50: "`",
        51: "delete", 53: "escape",
        64: "f17", 65: "keypad.", 67: "keypad*", 69: "keypad+", 71: "keypadclear",
        75: "keypad/", 76: "enter", 78: "keypad-", 79: "f18", 80: "f19", 81: "keypad=",
        82: "keypad0", 83: "keypad1", 84: "keypad2", 85: "keypad3", 86: "keypad4",
        87: "keypad5", 88: "keypad6", 89: "keypad7", 90: "f20", 91: "keypad8", 92: "keypad9",
        96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9", 103: "f11",
        105: "f13", 106: "f16", 107: "f14", 109: "f10", 111: "f12", 113: "f15",
        115: "home", 116: "pageup", 117: "forwarddelete", 118: "f4", 119: "end",
        120: "f2", 121: "pagedown", 122: "f1",
        123: "left", 124: "right", 125: "down", 126: "up"
    ]
}
