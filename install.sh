#!/bin/bash
# One-shot installer for AgentPulse.
#
#   curl -fsSL https://raw.githubusercontent.com/fanook/agentpulse/main/install.sh | bash
#
# What it does (all local, no network egress beyond the clone):
#   1. Ensures Xcode Command Line Tools are installed (for swiftc).
#   2. Ensures `jq` is on $PATH (brew install if missing).
#   3. Clones (or fast-forwards) the source into ~/.agentpulse-src.
#   4. Builds a release .app and copies it to /Applications.
#   5. Wires the Claude Code hook bridge into ~/.claude/settings.json.
#   6. Opens AgentPulse — the AP icon appears in the menu bar.
#
# Re-running is safe: the hook installer is idempotent and the build
# overwrites the previous .app in place.
set -euo pipefail

REPO_URL="https://github.com/fanook/agentpulse.git"
REPO_DIR="${AGENTPULSE_SRC:-$HOME/.agentpulse-src}"
APP_DEST="/Applications/AgentPulse.app"

BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

step()   { printf "%s▸%s %s\n" "$BLUE" "$RESET" "$1"; }
ok()     { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$1"; }
warn()   { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
die()    { printf "%s✗%s %s\n" "$RED" "$RESET" "$1" >&2; exit 1; }

# ── 0. Platform check ────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "AgentPulse is macOS-only."

# ── 1. Xcode Command Line Tools (provides swiftc) ────────────────────
step "Checking Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools missing. Launching the macOS installer dialog…"
    warn "Accept the prompt, wait for it to finish, then re-run this script."
    xcode-select --install || true
    exit 1
fi
ok "Command Line Tools present ($(xcode-select -p))"

if ! command -v swift >/dev/null 2>&1; then
    die "swift not on PATH even though CLT is installed. Try: sudo xcode-select --reset"
fi

# ── 2. jq for the hook installer ─────────────────────────────────────
step "Checking jq"
if ! command -v jq >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        warn "jq missing — installing via Homebrew"
        brew install jq
    else
        die "jq is required. Install Homebrew (https://brew.sh) and re-run, or \`brew install jq\` manually."
    fi
fi
ok "jq present ($(jq --version))"

# ── 3. Clone / update source ─────────────────────────────────────────
step "Fetching source into $REPO_DIR"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --quiet origin
    git -C "$REPO_DIR" reset --quiet --hard origin/HEAD
    ok "Updated existing clone"
else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet "$REPO_URL" "$REPO_DIR"
    ok "Cloned fresh"
fi

# ── 4. Build + bundle ────────────────────────────────────────────────
step "Building AgentPulse.app (release)"
cd "$REPO_DIR"
./scripts/make-app.sh >/dev/null
[ -d "build/AgentPulse.app" ] || die "Build finished but build/AgentPulse.app not found"
ok "Built build/AgentPulse.app"

# ── 5. Install to /Applications ──────────────────────────────────────
step "Installing to $APP_DEST"
# Stop the old one if it's running — otherwise the copy will be denied
# by the kernel on the mach-o file.
if pgrep -q AgentPulse; then
    warn "Stopping running AgentPulse instance"
    osascript -e 'tell application "AgentPulse" to quit' 2>/dev/null || killall AgentPulse 2>/dev/null || true
    sleep 1
fi
# Need admin perms to write into /Applications when running as a normal user.
if [ -w "/Applications" ]; then
    rm -rf "$APP_DEST"
    cp -R "build/AgentPulse.app" "$APP_DEST"
else
    warn "Administrator password needed to write into /Applications"
    sudo rm -rf "$APP_DEST"
    sudo cp -R "build/AgentPulse.app" "$APP_DEST"
fi
ok "Installed AgentPulse.app"

# ── 6. Claude Code hook bridge ───────────────────────────────────────
step "Wiring Claude Code hooks"
./hooks/claude/install.sh >/dev/null
ok "Hooks written to ~/.claude/settings.json"

# ── 7. Launch ────────────────────────────────────────────────────────
step "Launching"
open "$APP_DEST"
ok "AgentPulse is running — look for the ${BOLD}AP${RESET} wordmark in your menu bar."

cat <<EOF

${BOLD}Next steps${RESET}
  • Open any terminal and run \`claude\` as usual — sessions show up automatically.
  • Click the AP icon to open the capsule.
  • Right-click AP → Settings to enable launch-at-login or tweak behavior.

${DIM}Uninstall any time: ~/.agentpulse-src/uninstall.sh${RESET}
EOF
