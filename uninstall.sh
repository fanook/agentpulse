#!/bin/bash
# Uninstall AgentPulse, matching the install.sh footprint.
#
#   ~/.agentpulse-src/uninstall.sh
# or
#   curl -fsSL https://raw.githubusercontent.com/fanook/agentpulse/main/uninstall.sh | bash
set -euo pipefail

REPO_DIR="${AGENTPULSE_SRC:-$HOME/.agentpulse-src}"
APP_DEST="/Applications/AgentPulse.app"

step()   { printf "\033[0;34m▸\033[0m %s\n" "$1"; }
ok()     { printf "\033[0;32m✓\033[0m %s\n" "$1"; }
warn()   { printf "\033[0;33m!\033[0m %s\n" "$1"; }

# Stop the app so /Applications deletion isn't blocked by an open binary.
if pgrep -q AgentPulse; then
    step "Stopping AgentPulse"
    osascript -e 'tell application "AgentPulse" to quit' 2>/dev/null || killall AgentPulse 2>/dev/null || true
    sleep 1
fi

# 1. Claude Code hooks
if [ -d "$REPO_DIR/hooks/claude" ]; then
    step "Removing Claude Code hooks"
    "$REPO_DIR/hooks/claude/uninstall.sh" >/dev/null 2>&1 || true
    ok "Hooks removed from ~/.claude/settings.json"
else
    warn "Source directory missing at $REPO_DIR — skipping hook cleanup. Edit ~/.claude/settings.json manually if needed."
fi

# 2. /Applications/AgentPulse.app
if [ -d "$APP_DEST" ]; then
    step "Removing $APP_DEST"
    if [ -w "/Applications" ]; then
        rm -rf "$APP_DEST"
    else
        sudo rm -rf "$APP_DEST"
    fi
    ok "AgentPulse.app removed"
fi

# 3. User data — ask before deleting, this may hold session history.
for dir in \
    "$HOME/Library/Application Support/AgentPulse" \
    "$HOME/Library/Logs/AgentPulse" \
    "$HOME/.pulse"
do
    if [ -e "$dir" ]; then
        step "Removing $dir"
        rm -rf "$dir"
        ok "Gone"
    fi
done

# 4. Source clone — optional, keep by default so re-install is fast.
if [ -d "$REPO_DIR" ]; then
    printf "\n\033[2mKeep the source clone at %s? (for faster reinstall) [Y/n] \033[0m" "$REPO_DIR"
    read -r reply </dev/tty 2>/dev/null || reply="y"
    case "${reply:-y}" in
        n|N) rm -rf "$REPO_DIR"; ok "Source removed" ;;
        *)   ok "Source kept at $REPO_DIR" ;;
    esac
fi

echo
echo "AgentPulse uninstalled."
