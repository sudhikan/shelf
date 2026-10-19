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
- Hides Apple's Dock by setting it to auto-hide with a 1000 s delay; turn off
  "Hide Apple's Dock" in Settings to restore it.
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
