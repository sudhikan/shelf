import AppKit

/// Now Playing for Music and Spotify. macOS restricts the system-wide Now Playing API
/// (MediaRemote) to Apple's own apps, so this uses each player's AppleScript interface plus
/// the track-change notifications both apps broadcast. Browser audio isn't covered.
@Observable
final class NowPlayingService {
    static let shared = NowPlayingService()

    enum Player: String {
        case music = "Music", spotify = "Spotify"
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
    }

    private(set) var player: Player?
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// Position at `positionDate`; extrapolated while playing.
    private(set) var position: TimeInterval = 0
    private(set) var positionDate = Date.now

    @ObservationIgnored private var started = false
    @ObservationIgnored private var artworkKey: String?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        for p in [Player.music, .spotify] {
            DistributedNotificationCenter.default().addObserver(forName: .init(p.notification), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NowPlayingService.shared.poll(preferring: p) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NowPlayingService.shared.poll() }
        }
        Task {
            while !Task.isCancelled {
                poll()
                try? await Task.sleep(for: .seconds(isPlaying ? 5 : 15))
            }
        }
    }

    func currentPosition(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, p), track.duration)
    }

    // MARK: Controls

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func openPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else {
            NSWorkspace.shared.open(URL(filePath: "/System/Applications/Music.app"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func command(_ verb: String) {
        guard let player else { return }
        _ = Self.run("tell application \"\(player.rawValue)\" to \(verb)")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            poll(preferring: player)
        }
    }

    // MARK: Polling

    private func isRunning(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty
    }

    /// Reads state from the running players (never launches one). A playing player wins.
    func poll(preferring preferred: Player? = nil) {
        guard DockStore.shared.hasWidget(.nowPlaying) else { return }
        let candidates = [preferred, player, .music, .spotify].compactMap { $0 }
        var seen = Set<String>()
        var best: (Player, Snapshot)?
        for p in candidates where seen.insert(p.rawValue).inserted && isRunning(p) {
            guard let snap = snapshot(p) else { continue }
            if snap.playing { best = (p, snap); break }
            if best == nil { best = (p, snap) }
        }
        guard let (p, snap) = best else {
            player = nil; track = nil; isPlaying = false; artwork = nil; artworkKey = nil
            return
        }
        player = p
        track = snap.track
        isPlaying = snap.playing
        position = snap.position
        positionDate = .now
        let key = "\(p.rawValue)|\(snap.track.title)|\(snap.track.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(p, artworkURL: snap.artworkURL)
        }
    }

    private struct Snapshot {
        var track: Track
        var playing: Bool
        var position: TimeInterval
        var artworkURL: String?
    }

    private func snapshot(_ p: Player) -> Snapshot? {
        let extra = p == .spotify ? " & \"\\n\" & (artwork url of t)" : ""
        let script = """
        tell application "\(p.rawValue)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & "\\n" & (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & ((duration of t) as string) & "\\n" & ((player position) as string)\(extra)
        end tell
        """
        guard let output = Self.run(script), output != "stopped" else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var duration = number(parts[4])
        if p == .spotify { duration /= 1000 } // Spotify reports milliseconds
        return Snapshot(track: Track(title: parts[1], artist: parts[2], album: parts[3], duration: duration),
                        playing: parts[0] == "playing",
                        position: number(parts[5]),
                        artworkURL: parts.count > 6 ? parts[6] : nil)
    }

    private func loadArtwork(_ p: Player, artworkURL: String?) {
        if p == .music {
            var error: NSDictionary?
            let result = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?
                .executeAndReturnError(&error)
            if let data = result?.data, !data.isEmpty { artwork = NSImage(data: data) }
        } else if let urlString = artworkURL, let url = URL(string: urlString) {
            let key = artworkKey
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), artworkKey == key else { return }
                artwork = NSImage(data: data)
            }
        }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
