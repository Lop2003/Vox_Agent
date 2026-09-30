#!/bin/sh
# Runs the Vox Agent bridge as a login service (launchd): starts when you log in and restarts if it dies.
#
# Usage: scripts/bridge-service.sh install <workspace>   install or switch workspace
#        scripts/bridge-service.sh uninstall
#        scripts/bridge-service.sh status | code | logs
#
# The service gets the PATH of the shell you install from, so claude / codex / ollama are found.
# API keys (e.g. OPENROUTER_API_KEY) are not copied: put them in the agent's "env" in ~/.voxcode/agents.json.
set -eu

LABEL=com.voxagent.bridge
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/.voxcode/bridge.log"

case "${1:-}" in
install)
    WORKSPACE="$(cd "${2:?usage: $0 install <workspace>}" && pwd)"
    NODE="$(command -v node)" || { echo "node not found on PATH" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.voxcode"
    chmod 700 "$HOME/.voxcode"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE</string>
        <string>$ROOT/bridge/voxcode-bridge.mjs</string>
        <string>--workspace</string>
        <string>$WORKSPACE</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$PATH</string></dict>
    <key>WorkingDirectory</key><string>$WORKSPACE</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    sleep 1
    echo "Bridge service running for $WORKSPACE"
    echo "Pairing code: $(cat "$HOME/.voxcode/pairing-code")"
    ;;
uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Bridge service removed."
    ;;
status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "^\s+(state|pid|last exit code) =" || echo "Not installed."
    ;;
code)
    cat "$HOME/.voxcode/pairing-code"; echo
    ;;
logs)
    tail -f "$LOG"
    ;;
*)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
