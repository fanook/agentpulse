#!/bin/bash
# Install the AgentPulse hook bridge into ~/.claude/settings.json.
# Merges with existing settings; preserves other hooks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/report.sh"
chmod +x "$REPORT"

SETTINGS_DIR="$HOME/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required. install with: brew install jq" >&2
  exit 1
fi

BACKUP="$SETTINGS.agentpulse.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "backup written to $BACKUP"

TMP="$(mktemp)"

# AgentPulse marks its hook entries with a sentinel in the command string so
# upgrades are idempotent. We also strip the legacy "# tap-hook" sentinel
# from older installs.
SENTINEL="# agentpulse-hook"
LEGACY_SENTINEL="# tap-hook"

jq --arg report "$REPORT" --arg sentinel "$SENTINEL" --arg legacy "$LEGACY_SENTINEL" '
  def pulse_cmd(evt): "\($report) \(evt) " + $sentinel;

  def strip_pulse(arr):
    (arr // []) | map(
      .hooks = ((.hooks // []) | map(
        select((.command // "") | contains($sentinel) | not)
        | select((.command // "") | contains($legacy)   | not)
      ))
    ) | map(select((.hooks // []) | length > 0));

  def add_pulse(arr; evt):
    strip_pulse(arr) + [{
      matcher: "",
      hooks: [{
        type: "command",
        command: pulse_cmd(evt),
        timeout: 5
      }]
    }];

  .hooks = (.hooks // {})
  | .hooks.SessionStart     = add_pulse(.hooks.SessionStart;     "SessionStart")
  | .hooks.Stop             = add_pulse(.hooks.Stop;             "Stop")
  | .hooks.Notification     = add_pulse(.hooks.Notification;     "Notification")
  | .hooks.SessionEnd       = add_pulse(.hooks.SessionEnd;       "SessionEnd")
  | .hooks.PreToolUse       = add_pulse(.hooks.PreToolUse;       "PreToolUse")
  | .hooks.PostToolUse      = add_pulse(.hooks.PostToolUse;      "PostToolUse")
  | .hooks.CwdChanged       = add_pulse(.hooks.CwdChanged;       "CwdChanged")
  | .hooks.UserPromptSubmit = add_pulse(.hooks.UserPromptSubmit; "UserPromptSubmit")
' "$SETTINGS" > "$TMP"

mv "$TMP" "$SETTINGS"
echo "agentpulse hooks installed into $SETTINGS"
echo "report script: $REPORT"
