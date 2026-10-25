import Foundation
import Shared

/// What the aggregator produced for one ingested event or flush.
enum InputAggregatorOutput: Sendable, Equatable {
    /// A button went down. Emitted immediately so capture can grab the "pressed" frame and the
    /// accessibility snapshot can be taken before the click has any effect.
    case mouseDown(InputMouseDown)
    /// First character key of a typing burst; the focused-element context should be captured now.
    case typingStarted(tsMs: Int64)
    case event(InputEventDraft)
    case dropped(InputDropReason)
}

struct InputMouseDown: Sendable, Equatable {
    let button: InputButton
    let tsMs: Int64
    let x: Double
    let y: Double
}

enum InputDropReason: String, Sendable, Equatable {
    /// Pointer moved too far between down and up: a drag, not a click.
    case drag
    /// Secure event input was enabled (password prompt etc.); any in-flight typing burst is discarded.
    case secureInput
}

/// An aggregated action before geometry, accessibility context and privacy checks are attached.
struct InputEventDraft: Sendable, Equatable {
    var kind: InputEventKind
    var tsMs: Int64
    var endTsMs: Int64
    var button: InputButton?
    var clickCount: Int?
    var modifiers: [String]
    var x: Double?
    var y: Double?
    var scrollDx: Double?
    var scrollDy: Double?
    var keyCombo: String?
    var typedCount: Int?
}

/// Pure state machine turning tap-level events into user-level actions. No system calls, so every
/// rule below is unit-testable with synthetic timestamps.
///
/// - **Click**: mouse-down paired with mouse-up. `tsMs` is the mouse-down time (the moment the user
///   decided), `endTsMs` the mouse-up time. A pointer that moved more than `dragThresholdPoints`
///   is a drag and is not a click.
/// - **Scroll**: ticks within `scrollBurstGapMs` coalesce into one event with summed point deltas.
/// - **Shortcut**: key-down with cmd or ctrl, or a content-free special key (return, tab, arrows,
///   F-keys...). Opt/shift-only key-downs produce characters on most layouts, so they are typing.
/// - **Typing**: character keys are only *counted*. A burst closes after `typingIdleMs` of silence,
///   or when any other action interleaves.
struct InputEventAggregator {
    static let dragThresholdPoints = 5.0
    static let scrollBurstGapMs: Int64 = 150
    static let typingIdleMs: Int64 = 1_500

    private struct PendingDown {
        let tsMs: Int64
        let x: Double
        let y: Double
        let modifiers: InputModifiers
        let clickCount: Int
    }

    private struct ScrollBurst {
        let startMs: Int64
        var lastMs: Int64
        let x: Double
        let y: Double
        let modifiers: InputModifiers
        var dx: Double
        var dy: Double
    }

    private struct TypingBurst {
        let startMs: Int64
        var lastMs: Int64
        var count: Int
    }

    private var downs: [InputButton: PendingDown] = [:]
    private var scroll: ScrollBurst?
    private var typing: TypingBurst?

    init() {}

    // MARK: - Ingest

    mutating func ingest(_ raw: RawInputEvent) -> [InputAggregatorOutput] {
        var outputs = closeIdleBursts(nowMs: raw.tsMs)

        switch raw.kind {
        case .mouseDown(let button):
            outputs += closeScroll()
            outputs += closeTyping()
            downs[button] = PendingDown(
                tsMs: raw.tsMs,
                x: raw.x,
                y: raw.y,
                modifiers: raw.modifiers,
                clickCount: raw.clickCount
            )
            outputs.append(.mouseDown(InputMouseDown(button: button, tsMs: raw.tsMs, x: raw.x, y: raw.y)))

        case .mouseUp(let button):
            guard let down = downs.removeValue(forKey: button) else { break }
            let distance = hypot(raw.x - down.x, raw.y - down.y)
            if distance > Self.dragThresholdPoints {
                outputs.append(.dropped(.drag))
            } else {
                outputs.append(.event(InputEventDraft(
                    kind: .click,
                    tsMs: down.tsMs,
                    endTsMs: max(raw.tsMs, down.tsMs),
                    button: button,
                    clickCount: max(1, down.clickCount, raw.clickCount),
                    modifiers: down.modifiers.names,
                    x: down.x,
                    y: down.y
                )))
            }

        case .scroll(let dx, let dy):
            outputs += closeTyping()
            if var burst = scroll {
                burst.lastMs = raw.tsMs
                burst.dx += dx
                burst.dy += dy
                scroll = burst
            } else {
                scroll = ScrollBurst(
                    startMs: raw.tsMs,
                    lastMs: raw.tsMs,
                    x: raw.x,
                    y: raw.y,
                    modifiers: raw.modifiers,
                    dx: dx,
                    dy: dy
                )
            }

        case .keyDown(let keyCode, let isRepeat, let secureInput):
            if secureInput {
                // Never keep anything typed while secure input is on, including the burst so far.
                typing = nil
                outputs.append(.dropped(.secureInput))
                break
            }

            let hasCommandOrControl = raw.modifiers.contains(.command) || raw.modifiers.contains(.control)
            if hasCommandOrControl || InputKeyNames.isSpecial(keyCode) {
                outputs += closeScroll()
                outputs += closeTyping()
                // Holding a key down must not flood the log with identical shortcuts.
                guard !isRepeat else { break }
                outputs.append(.event(InputEventDraft(
                    kind: .shortcut,
                    tsMs: raw.tsMs,
                    endTsMs: raw.tsMs,
                    modifiers: raw.modifiers.names,
                    keyCombo: InputKeyNames.combo(keyCode: keyCode, modifiers: raw.modifiers)
                )))
            } else {
                outputs += closeScroll()
                if var burst = typing {
                    burst.lastMs = raw.tsMs
                    burst.count += 1
                    typing = burst
                } else {
                    typing = TypingBurst(startMs: raw.tsMs, lastMs: raw.tsMs, count: 1)
                    outputs.append(.typingStarted(tsMs: raw.tsMs))
                }
            }
        }

        return outputs
    }

    // MARK: - Idle flushing

    /// Close bursts that have gone quiet. Call periodically while `nextFlushDeadlineMs` is non-nil.
    mutating func flush(nowMs: Int64) -> [InputAggregatorOutput] {
        closeIdleBursts(nowMs: nowMs)
    }

    /// Close everything regardless of idleness (monitor stopping).
    mutating func finish() -> [InputAggregatorOutput] {
        downs.removeAll()
        return closeScroll() + closeTyping()
    }

    /// Earliest time at which an open burst would close from idleness, if any burst is open.
    var nextFlushDeadlineMs: Int64? {
        let deadlines = [
            scroll.map { $0.lastMs + Self.scrollBurstGapMs },
            typing.map { $0.lastMs + Self.typingIdleMs }
        ].compactMap { $0 }
        return deadlines.min()
    }

    // MARK: - Burst closing

    private mutating func closeIdleBursts(nowMs: Int64) -> [InputAggregatorOutput] {
        var outputs: [InputAggregatorOutput] = []
        if let burst = scroll, nowMs - burst.lastMs > Self.scrollBurstGapMs {
            outputs += closeScroll()
        }
        if let burst = typing, nowMs - burst.lastMs > Self.typingIdleMs {
            outputs += closeTyping()
        }
        return outputs
    }

    private mutating func closeScroll() -> [InputAggregatorOutput] {
        guard let burst = scroll else { return [] }
        scroll = nil
        // A burst that nets to nothing (momentum tail) carries no information.
        guard burst.dx != 0 || burst.dy != 0 else { return [] }
        return [.event(InputEventDraft(
            kind: .scroll,
            tsMs: burst.startMs,
            endTsMs: burst.lastMs,
            modifiers: burst.modifiers.names,
            x: burst.x,
            y: burst.y,
            scrollDx: burst.dx,
            scrollDy: burst.dy
        ))]
    }

    private mutating func closeTyping() -> [InputAggregatorOutput] {
        guard let burst = typing else { return [] }
        typing = nil
        return [.event(InputEventDraft(
            kind: .typing,
            tsMs: burst.startMs,
            endTsMs: burst.lastMs,
            modifiers: [],
            typedCount: burst.count
        ))]
    }
}
