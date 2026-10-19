import SwiftUI

struct QuickActionsCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize

    var body: some View {
        Image(systemName: QuickActionRunner.shared.keepAwakeOn ? "bolt.badge.clock.fill" : "bolt.fill")
            .font(.system(size: tileSize * 0.4))
            .foregroundStyle(.yellow.gradient)
            .frame(width: tileSize * 0.8)
    }
}

struct QuickActionsExpanded: View {
    let dismiss: () -> Void
    @State private var editingShortcuts = false
    private var runner: QuickActionRunner { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Quick Actions", symbol: "bolt.fill")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BuiltInAction.allCases) { action in
                    ActionButton(title: action.title, symbol: action.symbol, active: runner.isActive(action)) {
                        // Let the popover close first so screenshots/lock don't capture it.
                        let keepsOpen = action == .keepAwake || action == .darkMode
                        if !keepsOpen { dismiss() }
                        Task {
                            if !keepsOpen { try? await Task.sleep(for: .milliseconds(250)) }
                            runner.run(action)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Label("Shortcuts", systemImage: "square.2.layers.3d").font(.subheadline.weight(.semibold))
                Spacer()
                Button(editingShortcuts ? "Done" : "Edit") {
                    editingShortcuts.toggle()
                    if editingShortcuts { runner.loadShortcuts() }
                }
                .buttonStyle(.link)
            }

            if editingShortcuts {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if runner.availableShortcuts.isEmpty {
                            ProgressView().controlSize(.small)
                        }
                        ForEach(runner.availableShortcuts, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { runner.pinnedShortcuts.contains(name) },
                                set: { _ in runner.toggleShortcutPinned(name) }))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else if runner.pinnedShortcuts.isEmpty {
                Text("Click Edit to add shortcuts from the Shortcuts app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(runner.pinnedShortcuts, id: \.self) { name in
                        Button { runner.runShortcut(name) } label: {
                            HStack {
                                if runner.running == name {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "play.fill").font(.caption)
                                }
                                Text(name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(active ? .white : .primary)
                    .background(active ? Color.accentColor : .primary.opacity(hovering ? 0.16 : 0.08), in: Circle())
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
