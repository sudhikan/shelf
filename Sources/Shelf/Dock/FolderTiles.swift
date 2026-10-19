import SwiftUI

/// A folder "stack": click to see its most recent items in a grid.
struct FolderTile: View {
    let path: String
    @State private var isOpen = false

    var body: some View {
        IconTile(label: FileManager.default.displayName(atPath: path)) {
            Image(nsImage: IconCache.icon(for: path))
                .resizable()
                .interpolation(.high)
        }
        .onTapGesture { isOpen.toggle() }
        .contextMenu {
            Button("Open in Finder") { NSWorkspace.shared.open(URL(filePath: path)) }
            Divider()
            Button("Remove from Dock") { DockStore.shared.removeFolder(path) }
        }
        .dockPopover(isPresented: $isOpen) {
            FolderGrid(path: path) { isOpen = false }
        }
    }
}

private struct FolderGrid: View {
    let path: String
    let dismiss: () -> Void
    @State private var items: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(FileManager.default.displayName(atPath: path)).font(.headline)
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(filePath: path))
                    dismiss()
                }
                .buttonStyle(.link)
            }
            if items.isEmpty {
                Text("Empty").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 4), spacing: 10) {
                        ForEach(items, id: \.self) { url in
                            FolderItem(url: url) { dismiss() }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { items = Self.load(path) }
    }

    private static func load(_ path: String) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(filePath: path), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        return Array(urls.sorted { date($0) > date($1) }.prefix(40))
    }
}

private struct FolderItem: View {
    let url: URL
    let opened: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(for: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 48, height: 48)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
        .padding(4)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(url)
            opened()
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Show in Finder") { AppActions.revealInFinder(url.path(percentEncoded: false)) }
        }
    }
}

struct TrashTile: View {
    @State private var isEmpty = TrashTile.trashIsEmpty()
    @State private var dropTargeted = false

    var body: some View {
        IconTile(label: "Trash") {
            Image(nsImage: TrashTile.icon(empty: isEmpty))
                .resizable()
                .interpolation(.high)
                .brightness(dropTargeted ? 0.15 : 0)
        }
        .onTapGesture { NSWorkspace.shared.open(URL.homeDirectory.appending(path: ".Trash")) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL.homeDirectory.appending(path: ".Trash")) }
            Button("Empty Trash") { QuickActionRunner.emptyTrash() }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { urls in
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                isEmpty = TrashTile.trashIsEmpty()
            }
            return true
        }
        .task {
            while !Task.isCancelled {
                isEmpty = TrashTile.trashIsEmpty()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private static func trashIsEmpty() -> Bool {
        let trash = URL.homeDirectory.appending(path: ".Trash")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: trash.path(percentEncoded: false))) ?? []
        return items.allSatisfy { $0.hasPrefix(".") }
    }

    private static func icon(empty: Bool) -> NSImage {
        let name = empty ? "TrashIcon" : "FullTrashIcon"
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns"
        return NSImage(contentsOfFile: path) ?? NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!
    }
}
