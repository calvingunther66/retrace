# Sourced by dev.sh and build_and_sign.sh — not meant to be run directly.
#
# Gracefully quits a running instance of the given app before its files get
# replaced out from under it. Prefers a normal AppleEvent quit (lets WAL/video
# segments finalize cleanly) over pkill, and only falls back to a forced kill
# if the app doesn't respond within a few seconds.
quit_running_app_gracefully() {
    local app_name="$1"
    pgrep -x "$app_name" >/dev/null 2>&1 || return 0
    echo "🛑 Quitting running $app_name instance..."
    osascript -e "tell application \"$app_name\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$app_name" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    echo "⚠️  $app_name didn't quit gracefully in time; forcing quit."
    pkill -x "$app_name" 2>/dev/null || true
    sleep 1
}
