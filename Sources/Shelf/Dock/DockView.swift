import SwiftUI
import UniformTypeIdentifiers

struct DockRootView: View {
    var body: some View {
        DockBar()
            .padding(.top, DockController.headroom)
            .padding(.horizontal, DockController.sidePadding) // room for hover labels at the ends
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                DockController.shared.contentSizeChanged($0)
            }
    }
}

struct DockBar: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @AppStorage(SettingsKey.showTrash) private var showTrash = false
    @AppStorage(SettingsKey.appRows) private var appRows = SettingsDefault.appRows
    /// Each widget's own width (independent of the space it's given, so no feedback loop).
    @State private var widgetWidths: [UUID: CGFloat] = [:]
    private var store: DockStore { .shared }

    /// Of the bar's width, apps get 40% and widgets 60%. Nothing changes height:
    /// the spare room in each area becomes even spacing.
    static let appShare: CGFloat = 0.4

    var body: some View {
        // Every running app gets an icon, however many kept apps there are.
        // Kept apps beyond what the row setting shows count as unkept, so they still appear while running.
        let pinned = store.visiblePinnedApps
        let apps = pinned.map { ($0, true) }
            + RunningApps.shared.unpinned(excluding: pinned).map { ($0, false) }
        let (appsWidth, widgetsWidth) = areaWidths(appCount: apps.count)

        HStack(alignment: .bottom, spacing: 2) {
            AppSlots(apps: apps, width: appsWidth)
            DockDivider()
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(store.config.widgets) { item in
                    WidgetTile(item: item)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widgetWidths[item.id] = $0 }
                    Spacer(minLength: 2) // spreads widgets evenly across their area
                }
                AddWidgetButton()
            }
            .frame(width: widgetsWidth)
            if !store.config.folders.isEmpty || showTrash {
                DockDivider()
                ForEach(store.config.folders, id: \.self) { path in
                    FolderTile(path: path)
                }
                if showTrash { TrashTile() }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .frame(height: tileSize + 16, alignment: .bottom)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .coordinateSpace(.named("dock"))
        // Floats above the bar's right end so entering edit mode doesn't re-lay out the dock.
        .overlay(alignment: .topTrailing) {
            if DockEditor.shared.isEditing {
                EditDoneButton().offset(x: -10, y: -(tileSize * 0.55 + 8))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Dropping an app anywhere on the bar pins it at the end of the apps.
            loadFileURLs(providers) { urls in
                for url in urls where url.pathExtension == "app" && DockStore.shared.canPinMore {
                    DockStore.shared.pin(url.path(percentEncoded: false).trimmingSuffix("/"))
                }
            }
            return true
        }
    }

    /// Smallest bar where apps get 40% and widgets 60% of the usual width, with apps beyond the
    /// usual slots widening the apps' area by a slot each. If that's wider than the screen, the
    /// widgets' spare room goes first, then the apps' area is squeezed and its icons shrink.
    private func areaWidths(appCount: Int) -> (apps: CGFloat, widgets: CGFloat) {
        let baseSlots = AppSlots.slotCount(rows: appRows)
        let cellWidth = AppSlots.minCellWidth(tileSize: tileSize, rows: appRows)
        let appsNeeded = CGFloat(baseSlots) * cellWidth
        let widgets = store.config.widgets
        let plusButton = tileSize * 0.55 + 4
        let widgetsNeeded = widgets.reduce(0) { $0 + (widgetWidths[$1.id] ?? 0) }
            + CGFloat(widgets.count) * 2 + plusButton
        let total = max(appsNeeded / Self.appShare, widgetsNeeded / (1 - Self.appShare))
        var apps = floor(total * Self.appShare) + CGFloat(max(0, appCount - baseSlots)) * cellWidth
        var widgetsWidth = ceil(total * (1 - Self.appShare))

        // Everything else in the bar: padding, dividers, folders and Trash (each tile + 4, spacing 2).
        let endTiles = store.config.folders.count + (showTrash ? 1 : 0)
        let rest = 12 + 2 * 13 + CGFloat(endTiles) * (tileSize + 6) + 8
        let available = DockController.shared.maxWidth - 2 * DockController.sidePadding
        let over = apps + widgetsWidth + rest - available
        if over > 0 {
            widgetsWidth -= min(over, max(0, widgetsWidth - ceil(widgetsNeeded)))
            let stillOver = apps + widgetsWidth + rest - available
            // Icons stop shrinking at 16 pt (a 22 pt slot).
            if stillOver > 0 { apps = max(CGFloat(appCount) * 22, floor(apps - stillOver)) }
        }
        return (apps, widgetsWidth)
    }
}

/// "+" at the end of the widgets: pick a widget to add.
struct AddWidgetButton: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Add Widget") {
                ForEach(WidgetKind.allCases) { kind in
                    let added = DockStore.shared.hasWidget(kind)
                    Toggle(isOn: Binding(get: { added }, set: { _ in DockStore.shared.addWidget(kind) })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .disabled(added)
                }
            }
            Divider()
            Button(DockEditor.shared.isEditing ? "Done Editing" : "Edit Dock") { DockEditor.shared.toggle() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: tileSize * 0.28, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: tileSize * 0.55, height: tileSize)
                .background(.primary.opacity(hovering ? 0.12 : 0.05), in: .rect(cornerRadius: tileSize * 0.2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Add a widget")
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
    }
}

/// App icons in evenly spaced slots across the apps' share of the bar.
/// One row: at least 8 full-size slots. Two rows: a zigzag of at least 10 — icons alternate
/// low/high, so no icon sits directly above another and each can use most of the bar's height.
/// Kept apps come first (left to right), then running apps that aren't kept. More apps than
/// slots add slots; when the bar is squeezed to fit the screen, icons shrink to their slot.
struct AppSlots: View {
    let apps: [(String, Bool)]
    let width: CGFloat
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @AppStorage(SettingsKey.appRows) private var appRows = SettingsDefault.appRows

    static func slotCount(rows: Int) -> Int { DockStore.appsPerRow * rows }

    /// Height available for icons: the bar's inner height (tile + 16 minus 8 padding).
    static func zigzag(tileSize: CGFloat) -> (icon: CGFloat, rise: CGFloat) {
        let available = tileSize + 8
        let dot: CGFloat = 5
        let icon = floor(tileSize * 0.78)
        return (icon, max(0, available - icon - dot))
    }

    static func minCellWidth(tileSize: CGFloat, rows: Int) -> CGFloat {
        rows == 2 ? zigzag(tileSize: tileSize).icon + 4 : tileSize + 6
    }

    var body: some View {
        let slots = max(Self.slotCount(rows: appRows), apps.count)
        let cell = width / CGFloat(slots)
        let (zigIcon, rise) = Self.zigzag(tileSize: tileSize)
        let icon = appRows == 2 ? min(zigIcon, cell - 4) : min(tileSize, floor(cell - 6))
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<slots, id: \.self) { index in
                let raised = appRows == 2 && index % 2 == 1
                Group {
                    if index < apps.count {
                        AppTile(path: apps[index].0, pinned: apps[index].1,
                                iconSize: icon < tileSize ? icon : nil)
                    } else {
                        Color.clear.frame(width: icon, height: icon)
                    }
                }
                .padding(.bottom, raised ? rise : 0)
                .frame(width: cell)
            }
        }
        .frame(width: width)
    }
}

struct DockDivider: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.18))
            .frame(width: 1, height: tileSize * 0.8)
            .padding(.horizontal, 5)
            .padding(.bottom, 8)
    }
}

// MARK: - Icon tile container

/// Wraps an icon-sized tile: hover label and running dot. No animation.
struct IconTile<Content: View>: View {
    let label: String
    var showsDot = false
    var dotActive = false
    /// Icon size override (the two-row grid uses smaller icons).
    var size: CGFloat?
    /// Grow on hover (apps only).
    var zooms = false
    /// Caller-owned hover state (AppTile needs it for stacking order); falls back to local state.
    var hoverState: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @AppStorage(SettingsKey.appZoom) private var appZoom = SettingsDefault.appZoom
    @State private var localHovering = false
    private var hovering: Bool { hoverState?.wrappedValue ?? localHovering }

    /// Only the hovered icon scales, as a pure transform: neighbours don't move and the
    /// window never resizes, which is what made the old magnification choppy.
    private func zoomScale(side: CGFloat, compact: Bool) -> CGFloat {
        guard zooms, hovering, appZoom > 1.01, !DockEditor.shared.isEditing else { return 1 }
        // Small grid icons zoom further, to about a full-size icon.
        return compact ? max(appZoom * 1.4, tileSize / side) : appZoom
    }

    var body: some View {
        let side = size ?? tileSize
        let compact = side < 32
        let scale = zoomScale(side: side, compact: compact)
        VStack(spacing: compact ? 1 : 2) {
            content()
                .frame(width: side, height: side)
                .scaleEffect(scale, anchor: .bottom)
                .animation(.easeOut(duration: 0.12), value: scale)
            Circle()
                .fill(.primary.opacity(dotActive ? 0.85 : 0.5))
                .frame(width: compact ? 3 : 4, height: compact ? 3 : 4)
                .opacity(showsDot ? 1 : 0)
        }
        .padding(.horizontal, compact ? 1 : 2)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if hovering {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .fixedSize()
                    .offset(y: -30 - (scale - 1) * side)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            if let hoverState { hoverState.wrappedValue = inside } else { localHovering = inside }
        }
    }
}

// MARK: - App tile

struct AppTile: View {
    let path: String
    let pinned: Bool
    var iconSize: CGFloat?
    @State private var dropTargeted = false
    @State private var hovering = false

    var body: some View {
        let running = RunningApps.shared.app(at: path)
        IconTile(label: AppActions.displayName(path),
                       showsDot: running != nil,
                       dotActive: running?.processIdentifier == RunningApps.shared.frontmostPID,
                       size: iconSize,
                       zooms: true,
                       hoverState: $hovering) {
            Image(nsImage: IconCache.icon(for: path))
                .resizable()
                .interpolation(.high)
                .brightness(dropTargeted ? 0.15 : 0)
                .opacity(running?.isHidden == true ? 0.5 : 1) // hidden apps look faded, like Apple's Dock
        }
        .gesture(DockEditor.holdToEditOrTap { AppActions.open(path) })
        .contextMenu { menu(running: running) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .dockEditable(id: "app:\(path)", group: pinned ? .apps : nil,
                      zIndex: hovering ? 1 : 0, // zoomed icon draws over its neighbours
                      onDelete: pinned ? { DockStore.shared.unpin(path) } : nil,
                      onMove: { DockStore.shared.movePinned(path, to: $0) })
    }

    @ViewBuilder
    private func menu(running: NSRunningApplication?) -> some View {
        if let running {
            Button(running.isHidden ? "Show" : "Hide") {
                running.isHidden ? running.unhide() : running.hide()
            }
        }
        Button("Show in Finder") { AppActions.revealInFinder(path) }
        Divider()
        Button(DockEditor.shared.isEditing ? "Done Editing" : "Edit Dock") { DockEditor.shared.toggle() }
        if pinned {
            Button("Remove from Dock") { DockStore.shared.unpin(path) }
        } else {
            Button("Keep in Dock") { DockStore.shared.pin(path) }
                .disabled(!DockStore.shared.canPinMore)
        }
        if let running {
            Divider()
            Button("Quit") { running.terminate() }
            Button("Force Quit") { running.forceTerminate() }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        loadFileURLs(providers) { urls in
            let apps = urls.filter { $0.pathExtension == "app" }
            if !apps.isEmpty, pinned {
                for app in apps {
                    DockStore.shared.movePinned(app.path(percentEncoded: false).trimmingSuffix("/"), before: path)
                }
            } else if apps.isEmpty {
                AppActions.open(files: urls, with: path)
            }
        }
        return true
    }
}

func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    nonisolated(unsafe) var urls: [URL] = []
    let lock = NSLock()
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.withLock { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let result = lock.withLock { urls }
        MainActor.assumeIsolated { completion(result) }
    }
}
