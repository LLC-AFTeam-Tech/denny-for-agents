#!/bin/bash
# Builds "Denny for Agents.app" into dist/ with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="dist/Denny for Agents.app"

swift build -c release --product DennyForAgents
swift build -c release --product denny-hook
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DennyForAgents" "$APP/Contents/MacOS/DennyForAgents"
cp "$BIN/denny-hook" "$APP/Contents/MacOS/denny-hook"
cp -R "$BIN/DennyForAgents_DennyForAgents.bundle" "$APP/Contents/Resources/"
cp remote/denny-hook.py "$APP/Contents/Resources/denny-hook.py"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/TrayIcon.png "$APP/Contents/Resources/TrayIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Denny for Agents</string>
    <key>CFBundleDisplayName</key><string>Denny for Agents</string>
    <key>CFBundleIdentifier</key><string>tech.afteam.denny-for-agents</string>
    <key>CFBundleExecutable</key><string>DennyForAgents</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd dist && rm -f DennyForAgents.zip && ditto -c -k --keepParent "Denny for Agents.app" DennyForAgents.zip)
echo "Built: $APP"
