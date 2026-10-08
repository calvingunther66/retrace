#!/bin/bash
# retracectl — one command-line entry point for driving Retrace without a human in the loop.
#
#   scripts/retracectl.sh <command> [args]
#
# App lifecycle (act on the INSTALLED app in /Applications and its live data):
#   status                 is it running, which build, DB/vector sizes
#   build                  ./build_and_sign.sh (quits the running app, reinstalls, relaunches)
#   quit | launch          graceful quit / open /Applications/Retrace.app
#   deeplink <url>         open a retrace:// URL (routes that exist: search?q=&app=&t=, timeline?t=)
#   search-ui <query>      shorthand: open the in-app search overlay on <query>
#   ask-enable|ask-disable opt in/out of the retrace://ask deeplink (off by default; a web page could otherwise trigger it)
#   ask "<question>"       run the in-app Ask AI on a question and print the answer + what evidence was used
#                          (uses the app's own OpenRouter key; sends matched screen text to the configured model)
#   screenshot [file]      screencapture of the main display (needs Screen Recording permission
#                          for whatever process runs this; reports failure instead of hanging)
#   logs [n]               tail the app's own log lines from the unified log
#
# Offline analysis (NEVER touches the live DB — works on a snapshot copy):
#   snapshot               VACUUM INTO a consistent copy + copy vectors.bin  -> $RETRACE_SNAP_DIR
#   cli <retrace-cli args> run retrace-cli (search, ai-context, bench, index-bench, vector-status, ask)
#                          against the snapshot; --db/--storage-dir are filled in for you
#
# Limits, stated honestly: the app has no in-process command bus, so beyond the deeplink routes above
# there is nothing here that can click arbitrary UI. Use the computer-use tools for that.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="Retrace"
LIVE_DIR="$HOME/Library/Application Support/Retrace"
SNAP_DIR="${RETRACE_SNAP_DIR:-${TMPDIR:-/tmp}/retrace-snap}"
CONFIG="${RETRACE_CLI_CONFIG:-release}"   # release: bundled SQLite is unoptimized in debug, which skews timings
CLI_BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null || echo "$ROOT/.build/out/Products/Release")"

cmd="${1:-help}"; shift || true

case "$cmd" in
  status)
    if pgrep -x "$APP_NAME" >/dev/null; then echo "running: pid $(pgrep -x "$APP_NAME" | head -1)"; else echo "not running"; fi
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/$APP_NAME.app/Contents/Info.plist" 2>/dev/null | sed 's/^/version: /'
    stat -f "installed binary mtime: %Sm" "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null
    ls -l "$LIVE_DIR/retrace.db" "$LIVE_DIR/vectors.bin" 2>/dev/null | awk '{print $5, $NF}'
    ;;
  build)
    echo "This quits the running Retrace (recording pauses), reinstalls to /Applications and relaunches." >&2
    exec ./build_and_sign.sh "$@"
    ;;
  quit)
    source scripts/quit_app_gracefully.sh
    quit_running_app_gracefully "$APP_NAME"
    pgrep -x "$APP_NAME" >/dev/null && { echo "still running"; exit 1; } || echo "quit"
    ;;
  launch)
    open "/Applications/$APP_NAME.app" && echo "launched"
    ;;
  deeplink)
    [ $# -ge 1 ] || { echo "usage: deeplink <retrace://...>"; exit 2; }
    case "$1" in retrace://*) ;; *) echo "only retrace:// URLs are accepted"; exit 2;; esac
    open "$1" && echo "sent $1"
    ;;
  search-ui)
    [ $# -ge 1 ] || { echo "usage: search-ui <query>"; exit 2; }
    q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(" ".join(sys.argv[1:])))' "$@")
    open "retrace://search?q=$q" && echo "opened search for: $*"
    ;;
  ask-enable)  defaults write io.retrace.app allowAskDeeplink -bool true && echo "retrace://ask enabled" ;;
  ask-disable) defaults write io.retrace.app allowAskDeeplink -bool false && echo "retrace://ask disabled" ;;
  ask)
    [ $# -ge 1 ] || { echo "usage: ask \"<question>\""; exit 2; }
    [ "$(defaults read io.retrace.app allowAskDeeplink 2>/dev/null)" = "1" ] || { echo "ask deeplink is disabled; run: $0 ask-enable"; exit 1; }
    pgrep -x "$APP_NAME" >/dev/null || { echo "Retrace is not running (use: $0 launch)"; exit 1; }
    RESULT="$LIVE_DIR/ai_ask_last.json"; rm -f "$RESULT"
    q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(" ".join(sys.argv[1:]), safe=""))' "$@")
    open "retrace://ask?q=$q"
    for _ in $(seq 1 "${RETRACE_ASK_TIMEOUT:-150}"); do
      sleep 1
      [ -f "$RESULT" ] || continue
      st=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$RESULT" 2>/dev/null)
      [ "$st" = "running" ] || [ -z "$st" ] || break
    done
    python3 - "$RESULT" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("no result (timed out, or the app did not start the run):", e); sys.exit(1)
print("status :", d.get("status"), "| model:", d.get("model", "?"), "| elapsed:", d.get("elapsedMs", "?"), "ms")
print("plan   :", d.get("plan", ""))
for n in d.get("notes", []): print("note   :", n)
for e in d.get("evidence", []): print("evidence:", e)
print("cited  :", d.get("citedFrameIDs", []))
if d.get("error"): print("error  :", d["error"])
print("\n" + (d.get("answer") or ""))
PY
    ;;
  screenshot)
    out="${1:-${TMPDIR:-/tmp}/retrace-shot-$(date +%H%M%S).png}"
    if screencapture -x "$out" 2>/dev/null && [ -s "$out" ]; then echo "$out"; else echo "screencapture failed (Screen Recording permission for this process?)"; exit 1; fi
    ;;
  logs)
    log show --last 2m --predicate 'process == "Retrace"' --style compact 2>/dev/null | tail -n "${1:-50}"
    ;;
  snapshot)
    mkdir -p "$SNAP_DIR"; rm -f "$SNAP_DIR/retrace.db" "$SNAP_DIR/retrace.db-"*
    cp "$LIVE_DIR/vectors.bin" "$SNAP_DIR/" 2>/dev/null
    sqlite3 "file:$LIVE_DIR/retrace.db?mode=ro" "VACUUM INTO '$SNAP_DIR/retrace.db'" && echo "snapshot: $SNAP_DIR" && ls -l "$SNAP_DIR"
    ;;
  cli)
    [ -f "$SNAP_DIR/retrace.db" ] || { echo "no snapshot at $SNAP_DIR — run: $0 snapshot"; exit 1; }
    [ -x "$CLI_BIN_DIR/retrace-cli" ] || swift build -c "$CONFIG" --product retrace-cli >&2 || exit 1
    export DYLD_LIBRARY_PATH="$ROOT/Vendors/llama/lib:$ROOT/Vendors/whisper/lib"
    "$CLI_BIN_DIR/retrace-cli" "$@" --db "$SNAP_DIR/retrace.db" --storage-dir "$SNAP_DIR" 2>&1 | grep --line-buffered -E '^(»|error:)' | sed -u 's/^»//'
    ;;
  *)
    sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    ;;
esac
