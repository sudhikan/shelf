import SwiftUI

/// A widget in the dock: a compact live view; click for the expanded panel.
struct WidgetTile: View {
    let item: WidgetItem
    @State private var isOpen = false
    @State private var hovering = false
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize

    var body: some View {
        compact
            .fixedSize(horizontal: true, vertical: false) // always its natural width, never squeezed
            .frame(height: tileSize)
            .padding(.horizontal, 6)
            .background(.primary.opacity(hovering || isOpen ? 0.12 : 0.05),
                        in: .rect(cornerRadius: tileSize * 0.24))
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DockEditor.holdToEditOrTap { isOpen.toggle() })
            .contextMenu {
                Button(DockEditor.shared.isEditing ? "Done Editing" : "Edit Dock") { DockEditor.shared.toggle() }
                Divider()
                Button("Remove \(item.kind.title) Widget") { DockStore.shared.removeWidget(item.id) }
            }
            .dockEditable(id: "widget:\(item.id.uuidString)", group: .widgets,
                          onDelete: { DockStore.shared.removeWidget(item.id) },
                          onMove: { DockStore.shared.moveWidget(item.id, to: $0) })
            .onChange(of: DockEditor.shared.isEditing) { _, editing in if editing { isOpen = false } }
            .dockPopover(isPresented: $isOpen) {
                expanded
            }
    }

    @ViewBuilder
    private var compact: some View {
        switch item.kind {
        case .calendar: CalendarCompact()
        case .timer: TimerCompact()
        case .clipboard: ClipboardCompact()
        case .stocks: StocksCompact()
        case .quickActions: QuickActionsCompact()
        case .weather: WeatherCompact()
        case .nowPlaying: NowPlayingCompact()
        case .worldClock: WorldClockCompact()
        case .system: SystemCompact()
        case .notes: NotesCompact()
        }
    }

    @ViewBuilder
    private var expanded: some View {
        switch item.kind {
        case .calendar: CalendarExpanded()
        case .timer: TimerExpanded()
        case .clipboard: ClipboardExpanded { isOpen = false }
        case .stocks: StocksExpanded()
        case .quickActions: QuickActionsExpanded { isOpen = false }
        case .weather: WeatherExpanded()
        case .nowPlaying: NowPlayingExpanded()
        case .worldClock: WorldClockExpanded()
        case .system: SystemExpanded()
        case .notes: NotesExpanded()
        }
    }
}

// MARK: - Popover plumbing

extension View {
    /// A widget's expanded view, shown in a non-activating panel above the tile.
    /// Keeps the dock visible while open; typing works without stealing focus from your app.
    func dockPopover<Content: View>(isPresented: Binding<Bool>,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(DockPopoverModifier(isPresented: isPresented, popover: content))
    }
}

private struct DockPopoverModifier<Popover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let popover: () -> Popover
    /// The tile's frame in the dock window (SwiftUI global space: top-left origin).
    @State private var tileFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tileFrame = $0 }
            .onChange(of: isPresented) { _, open in
                if open {
                    let anchor = DockController.shared.screenRect(fromDockRect: tileFrame)
                    DockPopover.shared.show(anchor: anchor, onClose: { isPresented = false }) {
                        popover()
                    }
                } else {
                    DockPopover.shared.close(notify: false)
                }
            }
    }
}

/// Section header used inside expanded widgets.
struct WidgetHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            trailing()
        }
    }
}

extension WidgetHeader where Trailing == EmptyView {
    init(title: String, symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}
