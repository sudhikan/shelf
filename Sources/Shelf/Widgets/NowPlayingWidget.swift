import SwiftUI

struct NowPlayingCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var service: NowPlayingService { .shared }

    var body: some View {
        Group {
            if let track = service.track {
                HStack(spacing: 7) {
                    Artwork(image: service.artwork, size: tileSize * 0.72)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: tileSize * 1.7, alignment: .leading)
                    Button { service.playPause() } label: {
                        Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: tileSize * 0.28))
                            .frame(width: tileSize * 0.45, height: tileSize * 0.6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: tileSize * 0.4))
                    .foregroundStyle(.pink)
                    .frame(width: tileSize * 0.8)
            }
        }
        .onAppear { service.start() }
    }
}

struct NowPlayingExpanded: View {
    private var service: NowPlayingService { .shared }

    var body: some View {
        VStack(spacing: 12) {
            if let track = service.track {
                Artwork(image: service.artwork, size: 220)
                VStack(spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    Text(track.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = service.currentPosition(at: context.date)
                    VStack(spacing: 3) {
                        ProgressView(value: track.duration > 0 ? position / track.duration : 0)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(position.clockString)
                            Spacer()
                            Text("-" + max(0, track.duration - position).clockString)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 28) {
                    Button { service.previous() } label: { Image(systemName: "backward.fill") }
                    Button { service.playPause() } label: {
                        Image(systemName: service.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    }
                    Button { service.next() } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 18))
                .buttonStyle(.borderless)
                Button("Open \(service.player?.rawValue ?? "Music")") { service.openPlayer() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Image(systemName: "music.note").font(.system(size: 36)).foregroundStyle(.pink)
                Text("Nothing playing in Music or Spotify").foregroundStyle(.secondary)
                Button("Open Music") { NSWorkspace.shared.open(URL(filePath: "/System/Applications/Music.app")) }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            service.start()
            service.poll()
        }
    }
}

private struct Artwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.pink.opacity(0.6), .purple.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.12))
    }
}
