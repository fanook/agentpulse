#!/bin/bash
# AgentPulse hook bridge for Claude Code.
# Reads Claude's hook JSON on stdin, enriches with terminal hints and
# fixed agent="claude" tag, POSTs to the local AgentPulse daemon.
#
# Usage (from settings.json hook config):
#   report.sh SessionStart | Stop | Notification | SessionEnd
#            | PreToolUse | PostToolUse | UserPromptSubmit | CwdChanged
set -u
EVENT="${1:-unknown}"
AGENT="claude"

# Daemon writes port + token here each run. If AgentPulse isn't running, the
# files may be stale or missing — curl fails fast and we exit 0 so Claude
# isn't blocked.
PULSE_DIR="${HOME}/.pulse"
PORT_FILE="${PULSE_DIR}/port"
TOKEN_FILE="${PULSE_DIR}/token"

PORT="${PULSE_PORT:-}"
if [ -z "$PORT" ] && [ -r "$PORT_FILE" ]; then
  PORT="$(tr -d '[:space:]' < "$PORT_FILE")"
fi
PORT="${PORT:-9876}"

TOKEN=""
if [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

ENDPOINT="http://127.0.0.1:${PORT}/hook"

PAYLOAD="$(cat 2>/dev/null || true)"

extract() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$PAYLOAD" \
      | tr -d '\n' \
      | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n1 \
      | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
  fi
}

SESSION_ID="$(extract session_id)"
CWD="$(extract cwd)"
TRANSCRIPT="$(extract transcript_path)"
NOTIF="$(extract notification_type)"
EXIT_REASON="$(extract exit_reason)"
TOOL_NAME="$(extract tool_name)"

TOOL_SUMMARY=""
if [ -n "$TOOL_NAME" ] && command -v jq >/dev/null 2>&1; then
  case "$TOOL_NAME" in
    Edit|Write|Read|NotebookEdit)
      TOOL_SUMMARY="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null | awk -F/ '{print $NF}')"
      ;;
    Bash)
      TOOL_SUMMARY="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null | awk '{print $1}')"
      ;;
    Glob|Grep)
      TOOL_SUMMARY="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.pattern // empty' 2>/dev/null | cut -c1-30)"
      ;;
  esac
fi

if [ -z "$CWD" ]; then
  CWD="$(pwd 2>/dev/null || echo '')"
fi

TTY_VAL="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"

# Walk the process tree from our parent up to ~6 ancestors, looking for a
# known editor/terminal app. This is the only reliable way to tell Cursor
# from VS Code (Cursor is a fork that inherits TERM_PROGRAM=vscode).
HOST_APP=""
detect_host_app() {
  local pid="$PPID"
  for _ in 1 2 3 4 5 6; do
    [ -z "$pid" ] || [ "$pid" -le 1 ] && return
    local comm
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $NF}' | xargs basename 2>/dev/null)"
    case "$comm" in
      Cursor)                       HOST_APP="Cursor"; return ;;
      "Code"|"Code - Insiders")     HOST_APP="VS Code"; return ;;
      Windsurf)                     HOST_APP="Windsurf"; return ;;
      Zed)                          HOST_APP="Zed"; return ;;
      Ghostty)                      HOST_APP="Ghostty"; return ;;
      WezTerm|wezterm-gui)          HOST_APP="WezTerm"; return ;;
      Warp|"Warp Stable")           HOST_APP="Warp"; return ;;
      kitty)                        HOST_APP="kitty"; return ;;
      Alacritty)                    HOST_APP="Alacritty"; return ;;
      Hyper)                        HOST_APP="Hyper"; return ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
}
detect_host_app

json_str() {
  local v="$1"
  if [ -z "$v" ]; then printf 'null'; return; fi
  if command -v python3 >/dev/null 2>&1; then
    V="$v" python3 -c 'import json,os; print(json.dumps(os.environ["V"]), end="")'
  else
    local esc="${v//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '"%s"' "$esc"
  fi
}

TMUX_SOCKET=""
if [ -n "${TMUX:-}" ]; then
  TMUX_SOCKET="$(printf '%s' "$TMUX" | cut -d, -f1)"
fi

BODY=$(cat <<EOF
{
  "event": $(json_str "$EVENT"),
  "session_id": $(json_str "$SESSION_ID"),
  "agent": $(json_str "$AGENT"),
  "cwd": $(json_str "$CWD"),
  "transcript_path": $(json_str "$TRANSCRIPT"),
  "notification_type": $(json_str "$NOTIF"),
  "exit_reason": $(json_str "$EXIT_REASON"),
  "tool_name": $(json_str "$TOOL_NAME"),
  "tool_summary": $(json_str "$TOOL_SUMMARY"),
  "terminal": {
    "termProgram": $(json_str "${TERM_PROGRAM:-}"),
    "iTermSessionId": $(json_str "${ITERM_SESSION_ID:-}"),
    "tmuxPane": $(json_str "${TMUX_PANE:-}"),
    "tmuxSocket": $(json_str "$TMUX_SOCKET"),
    "wezTermPane": $(json_str "${WEZTERM_PANE:-}"),
    "terminalEmulator": $(json_str "${TERMINAL_EMULATOR:-}"),
    "bundleIdentifier": $(json_str "${__CFBundleIdentifier:-}"),
    "hostApp": $(json_str "$HOST_APP"),
    "ppid": $PPID,
    "tty": $(json_str "$TTY_VAL")
  }
}
EOF
)

curl -sS --max-time 1 -X POST \
  -H 'Content-Type: application/json' \
  -H "X-AgentPulse-Token: ${TOKEN}" \
  --data "$BODY" "$ENDPOINT" >/dev/null 2>&1 || true

LOG_DIR="$HOME/Library/Logs/AgentPulse"
mkdir -p "$LOG_DIR" 2>/dev/null || true
echo "[$(date '+%F %T')] claude $EVENT session=$SESSION_ID cwd=$CWD" >> "$LOG_DIR/hooks.log" 2>/dev/null || true

exit 0
