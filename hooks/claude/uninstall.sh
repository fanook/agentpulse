#!/bin/bash
# Remove AgentPulse hook entries from ~/.claude/settings.json.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
  echo "no settings.json, nothing to do"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

SENTINEL="# agentpulse-hook"
LEGACY_SENTINEL="# tap-hook"
TMP="$(mktemp)"

jq --arg sentinel "$SENTINEL" --arg legacy "$LEGACY_SENTINEL" '
  def strip(arr):
    (arr // []) | map(
      .hooks = ((.hooks // []) | map(
        select((.command // "") | contains($sentinel) | not)
        | select((.command // "") | contains($legacy)   | not)
      ))
    ) | map(select((.hooks // []) | length > 0));

  def prune(k):
    if (.hooks[k] // []) | length == 0 then del(.hooks[k]) else . end;

  .hooks.SessionStart       = strip(.hooks.SessionStart)
  | .hooks.Stop             = strip(.hooks.Stop)
  | .hooks.Notification     = strip(.hooks.Notification)
  | .hooks.SessionEnd       = strip(.hooks.SessionEnd)
  | .hooks.PreToolUse       = strip(.hooks.PreToolUse)
  | .hooks.PostToolUse      = strip(.hooks.PostToolUse)
  | .hooks.CwdChanged       = strip(.hooks.CwdChanged)
  | .hooks.UserPromptSubmit = strip(.hooks.UserPromptSubmit)
  | prune("SessionStart") | prune("Stop") | prune("Notification") | prune("SessionEnd")
  | prune("PreToolUse") | prune("PostToolUse") | prune("CwdChanged")
  | prune("UserPromptSubmit")
  | if (.hooks // {}) == {} then del(.hooks) else . end
' "$SETTINGS" > "$TMP"

mv "$TMP" "$SETTINGS"
echo "agentpulse hooks removed from $SETTINGS"
