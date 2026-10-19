#!/bin/zsh
# Builds Shelf.app, signs it with the local "Shelf Local Signing" identity,
# installs it to ~/Applications and (re)launches it.
#   ./build.sh            build + install + launch
#   ./build.sh --no-run   build + install only
set -euo pipefail
cd "${0:A:h}"

APP_NAME=Shelf
IDENTITY="Shelf Local Signing"
BUILD_APP=".build/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
cp "$BIN" "$BUILD_APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUILD_APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$BUILD_APP/Contents/Resources/"

codesign --force --sign "$IDENTITY" "$BUILD_APP"

# Unload the launch agent (if any) so KeepAlive doesn't relaunch the old build mid-copy,
# then quit any copy launchd wasn't supervising.
AGENT_LABEL=local.shelf.app
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$APP_NAME" || true
  for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" "$INSTALL_APP"
echo "Installed $INSTALL_APP"

[[ "${1:-}" == "--no-run" ]] && exit 0
if [[ -f "$AGENT_PLIST" ]]; then
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"   # RunAtLoad starts it under launchd
else
  open "$INSTALL_APP"
fi
