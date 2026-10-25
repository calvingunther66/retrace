import CoreGraphics
import Foundation

// Raw, tap-level input records. These carry only what the privacy contract allows: positions,
// buttons, modifier flags and *key codes*. Typed characters are never read from the event stream
// (`keyboardEventUnicodeString` is never touched), so they cannot reach any later stage.

enum InputButton: String, Sendable, Hashable {
    case left
    case right
    case other
}

struct InputModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let command = InputModifiers(rawValue: 1 << 0)
    static let control = InputModifiers(rawValue: 1 << 1)
    static let option = InputModifiers(rawValue: 1 << 2)
    static let shift = InputModifiers(rawValue: 1 << 3)

    /// Canonical order used everywhere a combo is spelled out: cmd, ctrl, opt, shift.
    var names: [String] {
        var result: [String] = []
        if contains(.command) { result.append("cmd") }
        if contains(.control) { result.append("ctrl") }
        if contains(.option) { result.append("opt") }
        if contains(.shift) { result.append("shift") }
        return result
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(cgFlags: CGEventFlags) {
        var value: InputModifiers = []
        if cgFlags.contains(.maskCommand) { value.insert(.command) }
        if cgFlags.contains(.maskControl) { value.insert(.control) }
        if cgFlags.contains(.maskAlternate) { value.insert(.option) }
        if cgFlags.contains(.maskShift) { value.insert(.shift) }
        self = value
    }
}

struct RawInputEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case mouseDown(InputButton)
        case mouseUp(InputButton)
        case scroll(dx: Double, dy: Double)
        /// `secureInput` is `IsSecureEventInputEnabled()` sampled when the key arrived.
        case keyDown(keyCode: UInt16, isRepeat: Bool, secureInput: Bool)
    }

    let kind: Kind
    /// Wall-clock epoch milliseconds, stamped on the tap thread (before any actor hop) with the same
    /// clock and truncation as `frame.createdAt`.
    let tsMs: Int64
    /// Pointer location in global points, top-left origin (`CGEvent.location`).
    let x: Double
    let y: Double
    let modifiers: InputModifiers
    /// `mouseEventClickState` for mouse events; 0 otherwise.
    let clickCount: Int

    init(
        kind: Kind,
        tsMs: Int64,
        x: Double = 0,
        y: Double = 0,
        modifiers: InputModifiers = [],
        clickCount: Int = 0
    ) {
        self.kind = kind
        self.tsMs = tsMs
        self.x = x
        self.y = y
        self.modifiers = modifiers
        self.clickCount = clickCount
    }
}
