#!/bin/zsh
# Removes Shelf and puts Apple's Dock back the way it was.
#   ./uninstall.sh           remove the app and login item, restore Apple's Dock
#   ./uninstall.sh --purge   also delete Shelf's data, settings, permissions and signing certificate
set -u

LABEL=local.shelf.app
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Stopping Shelf…"
# Unload the login item first so it doesn't relaunch Shelf, then quit it. Shelf has to be gone
# before restoring the Dock, because while it runs it re-hides Apple's Dock every few seconds.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$AGENT_PLIST"
osascript -e 'quit app "Shelf"' 2>/dev/null
pkill -x Shelf 2>/dev/null
sleep 1

echo "Restoring Apple's Dock…"
previous=$(defaults read "$LABEL" appleDockPreviousAutoHide 2>/dev/null || echo 0)
defaults delete com.apple.dock autohide-delay 2>/dev/null
if [[ "$previous" == 1 ]]; then
  defaults write com.apple.dock autohide -bool true
else
  defaults write com.apple.dock autohide -bool false
fi
# Shelf turned on "minimize windows into application icon"; go back to the macOS default.
defaults delete com.apple.dock minimize-to-application 2>/dev/null
killall Dock

echo "Removing the app…"
rm -rf "$HOME/Applications/Shelf.app"

if [[ "${1:-}" == "--purge" ]]; then
  echo "Deleting Shelf's data, settings and permissions…"
  rm -rf "$HOME/Library/Application Support/Shelf"
  defaults delete "$LABEL" 2>/dev/null
  tccutil reset All "$LABEL" >/dev/null 2>&1
  security delete-identity -c "Shelf Local Signing" >/dev/null 2>&1 && echo "Removed the Shelf Local Signing certificate."
fi

echo "Done. Apple's Dock is back."
