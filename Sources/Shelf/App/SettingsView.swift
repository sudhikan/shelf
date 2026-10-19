import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Dock Items", systemImage: "square.grid.3x1.below.line.grid.1x2") { ItemsSettings() }
        }
        .frame(width: 480, height: 440)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @AppStorage(SettingsKey.autoHide) private var autoHide = SettingsDefault.autoHide
    @AppStorage(SettingsKey.appRows) private var appRows = SettingsDefault.appRows
    @AppStorage(SettingsKey.appZoom) private var appZoom = SettingsDefault.appZoom
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var appleDockHidden = AppleDock.isSuppressed

    var body: some View {
        Form {
            Section("Appearance") {
                Slider(value: $tileSize, in: 32...80, step: 2) { Text("Size") }
                Toggle("Zoom apps on hover", isOn: Binding(
                    get: { appZoom > 1.01 },
                    set: { appZoom = $0 ? SettingsDefault.appZoom : 1 }))
                if appZoom > 1.01 {
                    Slider(value: $appZoom, in: 1.2...2.2) { Text("Zoom amount") }
                }
                Picker("App rows", selection: $appRows) {
                    Text("1 row · 8 apps").tag(1)
                    Text("2 rows · 10 smaller apps").tag(2)
                }
            }
            Section("Behavior") {
                Toggle("Automatically hide and show the dock", isOn: $autoHide)
                LabeledContent("Show dock", value: "Move pointer to bottom edge or press ⌃⌥D")
                Toggle("Launch Shelf at login (and restart it if it crashes)", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
            }
            Section {
                Toggle("Hide Apple's Dock", isOn: $appleDockHidden)
                    .onChange(of: appleDockHidden) { _, on in AppleDock.setSuppressed(on) }
            } footer: {
                Text("Sets Apple's Dock to auto-hide with a very long delay, and keeps it that way. Minimized windows go into their app's icon in Shelf. Turn this off to bring Apple's Dock back.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ItemsSettings: View {
    @AppStorage(SettingsKey.showTrash) private var showTrash = false
    private var store: DockStore { .shared }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.prefix(DockStore.maxApps - store.config.pinnedApps.count).forEach { store.pin($0.path(percentEncoded: false).trimmingSuffix("/")) }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(store.config.pinnedApps, id: \.self) { path in
                    HStack {
                        Image(nsImage: IconCache.icon(for: path)).resizable().frame(width: 18, height: 18)
                        Text(AppActions.displayName(path))
                        Spacer()
                        Button { store.unpin(path) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
                .onMove { from, to in store.config.pinnedApps.move(fromOffsets: from, toOffset: to) }
                Button("Add App…") { addApp() }
                    .disabled(!store.canPinMore)
            } header: {
                Text("Apps")
            } footer: {
                Text("Up to \(DockStore.maxApps) apps (change rows in General); the rest of the dock is for widgets. Running apps that aren't kept fill any free app slots.")
                    .foregroundStyle(.secondary)
            }
            Section("Widgets") {
                ForEach(store.config.widgets) { item in
                    HStack {
                        Label(item.kind.title, systemImage: item.kind.symbol)
                        Spacer()
                        Button { store.removeWidget(item.id) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
                Menu("Add Widget") {
                    ForEach(WidgetKind.allCases.filter { !store.hasWidget($0) }) { kind in
                        Button { store.addWidget(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                }
                .fixedSize()
                .disabled(WidgetKind.allCases.allSatisfy(store.hasWidget))
            }
            Section {
                ForEach(store.config.folders, id: \.self) { path in
                    HStack {
                        Image(nsImage: IconCache.icon(for: path)).resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: path))
                        Spacer()
                        Button { store.removeFolder(path) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
                Button("Add Folder…") { addFolder() }
                Toggle("Show Trash", isOn: $showTrash)
            } header: {
                Text("Folders & Trash")
            } footer: {
                Text("In the dock: drag an app off the dock to remove it, right-click for more, drag icons to reorder.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach { store.addFolder($0.path(percentEncoded: false).trimmingSuffix("/")) }
        }
    }
}
