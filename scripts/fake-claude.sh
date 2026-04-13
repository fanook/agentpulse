#!/bin/bash
# End-to-end smoke test: push a scripted sequence of hook events at the AgentPulse daemon.
# Run the app first (swift run agentpulse &) and watch the menu bar.

set -u
PULSE_DIR="${HOME}/.pulse"
PORT="${PULSE_PORT:-$(tr -d '[:space:]' < "$PULSE_DIR/port" 2>/dev/null || echo 9876)}"
TOKEN="$(tr -d '[:space:]' < "$PULSE_DIR/token" 2>/dev/null || echo '')"
ENDPOINT="http://127.0.0.1:${PORT}/hook"

post() {
  curl -sS --max-time 1 -X POST \
    -H 'Content-Type: application/json' \
    -H "X-AgentPulse-Token: ${TOKEN}" \
    --data "$1" "$ENDPOINT" >/dev/null && echo "  ok" || echo "  failed"
}

sid1="fake-$(date +%s)-a"
sid2="fake-$(date +%s)-b"

echo "SessionStart for $sid1 (cwd=/tmp/alpha)"
post "{\"event\":\"SessionStart\",\"session_id\":\"$sid1\",\"cwd\":\"/tmp/alpha\",\"terminal\":{\"termProgram\":\"iTerm.app\"}}"
sleep 1

echo "SessionStart for $sid2 (cwd=/tmp/beta, JetBrains)"
post "{\"event\":\"SessionStart\",\"session_id\":\"$sid2\",\"cwd\":\"/tmp/beta\",\"terminal\":{\"terminalEmulator\":\"JetBrains-JediTerm\"}}"
sleep 1

echo "Notification idle_prompt on $sid1"
post "{\"event\":\"Notification\",\"session_id\":\"$sid1\",\"notification_type\":\"idle_prompt\"}"
sleep 2

echo "Stop on $sid2"
post "{\"event\":\"Stop\",\"session_id\":\"$sid2\"}"
sleep 1

echo "Notification permission_prompt on $sid2"
post "{\"event\":\"Notification\",\"session_id\":\"$sid2\",\"notification_type\":\"permission_prompt\"}"
sleep 2

echo "SessionEnd $sid1"
post "{\"event\":\"SessionEnd\",\"session_id\":\"$sid1\",\"exit_reason\":\"logout\"}"

echo "done. remaining should be $sid2 in 'permission' state."
