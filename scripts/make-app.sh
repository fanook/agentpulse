#!/bin/bash
# Build AgentPulse in release mode and wrap the executable in a minimal .app bundle.
# Output: ./build/AgentPulse.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Version precedence: explicit env → current git tag → short sha → "dev".
# make-dmg.sh / release CI pass VERSION in; local `./scripts/make-app.sh`
# picks it up automatically so the About pane stays in sync with the DMG.
if [ -z "${VERSION:-}" ]; then
    if TAG="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
        VERSION="${TAG#v}"
    elif SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
        VERSION="dev-$SHA"
    else
        VERSION="dev"
    fi
fi
export VERSION
echo "version: $VERSION"

echo "building release..."
swift build -c release

EXE="$ROOT/.build/release/agentpulse"
APP="$ROOT/build/AgentPulse.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/AgentPulse"
chmod +x "$APP/Contents/MacOS/AgentPulse"

# Ship the Claude Code hook bridge inside the bundle so users installed
# via the DMG can wire it up from the Settings pane without ever touching
# a shell. HookInstaller.swift reads this via Bundle.main.
cp "$ROOT/hooks/claude/report.sh" "$APP/Contents/Resources/report.sh"
chmod +x "$APP/Contents/Resources/report.sh"

# Prefer the checked-in icon. If it's missing (fresh clone that deleted
# Resources, CI without the asset, etc.) regenerate with the helper.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "icon: $APP/Contents/Resources/AppIcon.icns (checked-in)"
elif swift "$ROOT/scripts/generate_icon.swift" "$APP/Contents/Resources" >/dev/null 2>&1; then
    echo "icon: $APP/Contents/Resources/AppIcon.icns (regenerated)"
else
    echo "icon: missing, continuing without"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentPulse</string>
    <key>CFBundleDisplayName</key><string>AgentPulse</string>
    <key>CFBundleIdentifier</key><string>local.agentpulse.menubar</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleExecutable</key><string>AgentPulse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Swap the placeholder with the resolved version so the About pane shows
# the same string that appears in the DMG filename.
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
echo "run with: open $APP"
