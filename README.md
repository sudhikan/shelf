# Shelf

A personal macOS Dock replacement with widgets: Calendar, Timers, Clipboard, Stocks, Quick Actions,
Weather, Now Playing, World Clocks, System and Quick Notes. Built with SwiftUI + AppKit, local use only.

## Build

```sh
./build.sh            # build, sign, install to ~/Applications, relaunch
./build.sh --no-run   # build and install only
```

Builds with the Command Line Tools (no Xcode). Requires macOS 26+.

Signing uses a self-signed Keychain identity named **Shelf Local Signing**, so macOS keeps
permissions (Calendar, Location, Automation) across rebuilds. To recreate it on a new Mac, make a
code-signing certificate with that name (e.g. via `openssl` with `extendedKeyUsage=codeSigning`)
and import it into the login keychain.

## How it runs

- Launches at login and restarts after a crash via `~/Library/LaunchAgents/local.shelf.app.plist`
  (written by the app; toggle in Settings).
- Hides Apple's Dock by making it auto-hide with a 1000 s delay (it can't sit visibly under Shelf:
  it keeps tracking the mouse there and shows its own labels). Turn off "Hide Apple's Dock" in
  Settings to restore your original Dock settings.
- Keeps windows above Shelf while it stays visible. This needs Accessibility permission (Shelf asks
  once; after that use the button in Settings): windows that are opened, resized, zoomed or tiled
  under Shelf are trimmed to end at its top edge once they settle, and so are windows already under
  it when Shelf appears or grows. Dragging a window down past Shelf is left alone. Zoomed and tiled
  windows briefly fill the full height first, since only Apple's Dock can make macOS leave room.
- Auto-hides on full-screen Spaces regardless of the setting; move the pointer to the bottom edge
  to bring it up there. On displays with a notch, telling full screen apart from a zoomed window
  needs Accessibility permission too.
- Shows every running app, hidden ones faded. The bar grows to fit them; past the screen's width the
  widgets' spare room goes first, then icons shrink.
- Data lives in `~/Library/Application Support/Shelf` and the `local.shelf.app` defaults domain.

## Uninstall (go back to Apple's Dock)

```sh
./uninstall.sh           # remove Shelf, restore Apple's Dock
./uninstall.sh --purge   # …and delete Shelf's data, settings, permissions and signing certificate
```

The script stops Shelf and its login item, then turns Apple's Dock back on. Auto-hide goes back to
how you had it before Shelf, and minimized windows go back into the Dock. Finally it deletes
`~/Applications/Shelf.app`. Without `--purge` your notes, clipboard history and settings stay in
`~/Library/Application Support/Shelf`, so reinstalling picks up where you left off.

To do it by hand instead:

1. Quit Shelf from its menu bar icon. If it relaunches itself, run
   `launchctl bootout gui/$(id -u)/local.shelf.app` first.
2. Delete `~/Library/LaunchAgents/local.shelf.app.plist` and `~/Applications/Shelf.app`.
3. Restore Apple's Dock:
   ```sh
   defaults delete com.apple.dock autohide-delay
   defaults write com.apple.dock autohide -bool false
   defaults delete com.apple.dock minimize-to-application
   killall Dock
   ```
4. Optionally delete `~/Library/Application Support/Shelf`, run `defaults delete local.shelf.app`,
   and remove the "Shelf Local Signing" certificate in Keychain Access.

## Data sources

Everything is native macOS (EventKit, NSPasteboard, UserNotifications, IOKit, CoreLocation, MapKit,
AppleScript for Music/Spotify/Notes) except Stocks (Yahoo Finance's unofficial chart endpoint) and
Weather / city search ([Open-Meteo](https://open-meteo.com), free for non-commercial use with
attribution), which need no API keys.

## License

MIT — see [LICENSE](LICENSE).
