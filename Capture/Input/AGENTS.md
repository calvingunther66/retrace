# CAPTURE / Input: input event logging

Off by default (`CaptureConfig.inputEventLoggingEnabled`, independent of `captureOnMouseClick`). A second listen-only `CGEvent` tap (`InputEventMonitor`; `MouseClickMonitor` is untouched) feeds a pure `InputEventAggregator`, then a context lookup, then `InputPrivacyPolicy`, then `CaptureManager.onInputEvent`. The App layer persists events (`App/InputEventWriter.swift`) and links them to frames.

```
Capture/Input/
├── InputEventModels.swift          # RawInputEvent/InputModifiers/InputButton: tap-level records (key codes + flags, never characters)
├── InputKeyNames.swift             # ANSI virtual-key-code -> name table + special-key set (shortcut spelling only)
├── InputEventAggregator.swift      # Pure state machine: click pairing (+drag rejection), scroll bursts, shortcuts, typing counts
├── InputContext.swift              # InputContext + InputContextProviding (display, window, AX) seam
├── LiveInputContextProvider.swift  # Real display layout, window-under-pointer, AX hit-test + focused-field check + capped clickable-element snapshot
├── InputPrivacyPolicy.swift        # Fail-closed event policy, stats, event builder
└── InputEventMonitor.swift         # Actor + listen-only CGEvent tap (mouse, scroll, key-down); pump/completion split
```

Tests: `Capture/Tests/InputEventAggregatorTests.swift`, `InputEventMonitorTests.swift` (monitor flow with fake tap + context, policy, real-`CGEvent` conversion), `LiveInputContextProviderTests.swift`, and `CaptureInputEventSchedulingTests` in `CaptureTriggerSchedulingTests.swift` (forced mouse-down capture, refractory anchor, outcome reporting).

## Permissions

Input Monitoring (the tap; same permission as click capture) and Accessibility (lets the provider record *what* was clicked and verify secure fields / private windows). Without Accessibility, events are kept but tagged `privacyState = ax_unavailable` and export skips them by default.

## Capture scheduling additions (`CaptureManager`)

| Trigger | Priority | Settle | Source |
| --- | --- | --- | --- |
| `inputPre` | 4 | 0 s | Mouse-down while logging is on. **Bypasses the refractory window** (still yields to an executing capture) and does **not** start one. Persisted as `FrameCaptureTrigger.mouse`. |
| `inputPost` | 3 | 0.15 s | A logged action finished (click/scroll/shortcut/typing). Skipped for left clicks when `captureOnMouseClick` already covers them. |

The refractory window is anchored to the last *non-`inputPre`* capture (`lastRefractoryAnchorTime`), so the forced frame cannot swallow the settled post-click capture. With logging off, behavior is unchanged. `onInputPreCaptureOutcome` reports the stored forced frame's exact timestamp so the DB can match `downFrameId` without a time window.

## Privacy contract (do not weaken)

- Only key *codes* and modifier flags are read; `keyboardEventUnicodeString` is never touched (`InputRawEventFactoryTests` proves a Unicode payload does not survive). Typing is only a count; shortcuts are only a spelled-out combo (`cmd+shift+t`). Opt/Shift-only key-downs are typing (they produce characters), not shortcuts.
- AX is read for role/subrole/title/description/identifier/geometry only, **never `AXValue`**; names are truncated to 80 chars.
- **Fail-closed.** Dropped (and counted): a secure text field under the pointer *or holding keyboard focus* (in the frontmost app or the window owner's app), `IsSecureEventInputEnabled()`, excluded app, window-title pattern, private window. If a check cannot be completed the event is kept but tagged `privacyState != "ok"`.
- Never set an AX messaging timeout on the system-wide element (it is process-global); per-app elements only. Never pass `self` pointers into AX C callbacks (see `DisplaySwitchAXRegistry`).

## Latency

The tap callback stamps wall-clock time on the tap thread (same clock/truncation as `frame.createdAt`) and yields into a FIFO `AsyncStream`. The pump handles mouse-down immediately (forced `inputPre` capture + AX snapshot at mouse-down); slow AX work runs on a separate completion consumer and a dedicated serial queue with 0.2 s timeouts.

## Known limits

- Chromium/Electron only build their AX tree after `AXManualAccessibility` is set; the provider sets it once per process for apps it hit-tests (same switch the URL extractor uses), which can raise those apps' CPU while logging is on.
- Key names assume an ANSI layout (physical key positions).
- The forced mouse-down capture grabs the active display, not necessarily the clicked one (exports drop a `down` frame whose display differs).
