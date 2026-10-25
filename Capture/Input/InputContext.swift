import CoreGraphics
import Foundation
import Shared

/// Everything known about the screen around an input event, gathered off the tap thread.
struct InputContext: Sendable, Equatable {
    var displayID: UInt32?
    var displayPixelWidth: Int?
    var displayPixelHeight: Int?
    var displayScale: Double?
    var displays: [InputDisplayGeometry] = []

    var bundleID: String?
    /// The event happened in one of Retrace's own windows. Never logged, and never inspected with
    /// accessibility: AppKit answers AX queries on the main thread, so walking our own tree from the
    /// context queue starves the UI.
    var isOwnApp = false
    var windowTitle: String?
    /// Window under the pointer, global points, top-left origin.
    var windowFrame: CGRect?

    /// Whether the window under the pointer is a private/incognito browser window.
    /// `nil` = could not be determined (no AX), which is not the same as "no".
    var isPrivateWindow: Bool?

    /// Accessibility was queryable (permission granted and the app answered).
    var axAvailable = false
    /// Element under the pointer (clicks/scrolls) or the focused element (typing/shortcuts).
    var axTarget: InputAXTarget?
    var axElements: [InputAXElement] = []
    /// Skipped because a snapshot was already running or the budget ran out.
    var axSnapshotTruncated = false

    /// A secure text field has keyboard focus in the frontmost app or the app that owns the window
    /// under the pointer, even if the pointer is elsewhere (e.g. clicking "Sign in" while the
    /// password field is still focused).
    var focusedElementIsSecure = false

    /// The element under the pointer, or the focused element, is a secure text field.
    var isSecureField: Bool {
        (axTarget?.isSecureTextField ?? false) || focusedElementIsSecure
    }

    static let empty = InputContext()
}

protocol InputContextProviding: Sendable {
    /// - Parameters:
    ///   - point: Global top-left point (clicks, scrolls). `nil` means "the focused element" (typing, shortcuts).
    ///   - wantsElements: Also take the capped clickable-element snapshot of the window under `point`.
    func context(at point: CGPoint?, wantsElements: Bool) async -> InputContext
}
