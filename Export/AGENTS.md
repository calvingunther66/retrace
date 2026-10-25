# EXPORT Agent Instructions

You are responsible for the **Export** module: turning Retrace's input events and the frames around them into a privacy-filtered training dataset. It is used only by `retrace-cli export`; the app does not link it.

```
Export/
├── ExportDenyList.swift        # Parses the MCP server's retrace_mcp.toml [privacy] table (bundles, URL/window patterns, hidden segments) + matching
├── InputEventExporter.swift    # Gates events/frames, decodes + downscales frames, writes events.jsonl / frames/ / manifest.json
└── Tests/                      # ExportTests target (real in-memory DatabaseManager + synthetic image source)
```

## Output

`<out>/events.jsonl` (one event per line), `<out>/frames/<frameId>.jpg|png`, `<out>/manifest.json` (options + summary).

Per line: `t`, `end_t`, `type` (click|scroll|shortcut|typing), `button`, `count`, `mods`, `x`/`y` (global **points**, as in the example format), `px`/`py` (the same position in native display **pixels**, relative to the display), `scroll{dx,dy}`, `key` (e.g. `cmd+shift+t`), `typed` (count only), `display{id,w,h,scale}` (w/h in **pixels**), `displays[]`, `app`, `window{title,box}`, `url`, `pre_frame_id`, `down_frame_id`, `post_frame_id`, `pre_gap_ms`, `frames{pre,down,post}`, `img{w,h,x,y,scale}` (the action's position in the exported image), `ax{role,title,id,box}`, `ax_elements[{role,name,box}]`, `privacy`.

- `url` has its query string and fragment removed unless `--keep-url-query` (they routinely carry tokens and signatures).
- Boxes are `[x1, y1, x2, y2]` in points (matches the element-list format training code consumes).
- `pre_frame_id` is the strict last frame at or before mouse-down. `down_frame_id` is the forced mouse-down capture and may already show a pressed/open state. `post_frame_id` is the first frame at least 120 ms after the action settled.

## Privacy rules (do not weaken)

- **Mandatory deny-list**: the CLI refuses to run without `--config <retrace_mcp.toml>` (or `RETRACE_MCP_CONFIG`) unless `--no-deny-list` is passed explicitly.
- **Frame gates** (`ExportGate.check`): not redacted at capture time; `processingStatus` 2 or 7 only (OCR/phrase-redaction pass finished); `encodedAt` set; not queued for deletion; no unfinished `redaction` rewrite; video finalized. Anything else may still hold raw pixels.
- **Event gates**: link resolved; `privacyState == ok` (unless `--include-unverified`); not `redacted`; no secure text field; pre frame not stale (`--max-pre-gap-ms`, default 5000); the pre frame's display equals the event's display; deny-list on the event's app/window and the pre frame's segment (bundle, URL, window title, `hidden` tag).
- **Down/post frames are gated independently** (the user may have navigated to a deny-listed site after the click) and are omitted, not exported, when they fail.
- A skipped event writes **no pixels**. The exporter never loads the Keychain master key, so scrambled regions stay scrambled.
- Typed characters do not exist in the database, so they cannot be exported.

## Rules

- Depend on `Shared`, `Database` (public API only) and `Storage`. Do not import `Capture`/`Processing`/`Search`.
- New skip reasons must be added to `ExportSkipReason` and covered by a test that asserts no pixels were written.
- Tests use a real `DatabaseManager` and real SQL rows; image decoding is faked through `ExportFrameImageSource`.
