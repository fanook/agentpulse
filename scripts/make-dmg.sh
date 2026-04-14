#!/bin/bash
# Build AgentPulse.app and wrap it in a drag-to-install DMG.
# Output: build/AgentPulse-<version>.dmg
#
# The DMG is NOT signed or notarized — first-launch on another Mac will
# need the right-click → Open workaround documented in the README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Delegate version resolution to make-app.sh (single source of truth) and
# recover it from the built Info.plist so DMG filename and About pane
# can never drift apart.
./scripts/make-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build/AgentPulse.app/Contents/Info.plist" 2>/dev/null || echo "dev")"

APP="build/AgentPulse.app"
[ -d "$APP" ] || { echo "build/AgentPulse.app not found"; exit 1; }

DMG="build/AgentPulse-$VERSION.dmg"
rm -f "$DMG"

# Stage the DMG contents: the .app + a symlink to /Applications so the
# classic drag-to-install gesture works without user typing anything.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "AgentPulse" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

echo "built: $DMG ($(du -h "$DMG" | cut -f1))"
echo "open with: open '$DMG'"
