import SwiftUI

/// iOS-style edit mode for the dock: tiles wiggle, show a delete badge, and can be dragged
/// to a new spot (or up off the dock to remove). Taps don't launch anything while editing.
@Observable
final class DockEditor {
    static let shared = DockEditor()

    enum Group { case apps, widgets }

    private(set) var isEditing = false
    /// One shared beat for every tile's wiggle, flipped by a single timer while editing.
    /// Tiles never run their own animations, so they can't drift or get stuck.
    private(set) var wiggleTick = false

    @ObservationIgnored private var wiggleTimer: Timer?
    static let wiggleInterval: TimeInterval = 0.14

    /// Tile frames in the dock's coordinate space, used to work out where a drag lands.
    @ObservationIgnored var frames: [String: CGRect] = [:]

    func begin() {
        guard !isEditing else { return }
        isEditing = true
        DockController.shared.hold()
        let timer = Timer(timeInterval: Self.wiggleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DockEditor.shared.wiggleTick.toggle() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps ticking during drags
        wiggleTimer = timer
    }

    func end() {
        guard isEditing else { return }
        wiggleTimer?.invalidate()
        wiggleTimer = nil
        isEditing = false
        wiggleTick = false
        DockController.shared.release()
    }

    func toggle() { isEditing ? end() : begin() }

    /// Hold a tile for half a second to start editing; a quick click runs `tap` instead.
    /// One combined gesture, so the hold always wins and a held click never also "taps".
    static func holdToEditOrTap(_ tap: @escaping () -> Void) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in DockEditor.shared.begin() }
            .exclusively(before: TapGesture().onEnded(tap))
    }

    /// Index among the group's *other* tiles where a tile dropped at `point` belongs.
    /// Works for a single row and for the two-row app grid: find the nearest tile,
    /// then go before or after it depending on which side of its centre we landed.
    func dropIndex(for id: String, in group: Group, at point: CGPoint) -> Int {
        let others = orderedIDs(group).filter { $0 != id }
        let placed = others.enumerated().compactMap { i, other in frames[other].map { (i, $0) } }
        guard let (index, frame) = placed.min(by: { distance($0.1, point) < distance($1.1, point) }) else {
            return others.count
        }
        return point.x > frame.midX ? index + 1 : index
    }

    private func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(frame.midX - point.x, (frame.midY - point.y) * 1.5) // rows count a bit more than columns
    }

    private func orderedIDs(_ group: Group) -> [String] {
        switch group {
        case .apps: DockStore.shared.config.pinnedApps.map { "app:\($0)" }
        case .widgets: DockStore.shared.config.widgets.map { "widget:\($0.id.uuidString)" }
        }
    }
}

extension View {
    /// Makes a dock tile take part in edit mode.
    /// - Parameters:
    ///   - group: tiles only reorder within their own group. Nil = wiggles but can't move.
    ///   - onDelete: shows the delete badge; nil = no badge (e.g. running apps that aren't kept).
    ///   - onMove: called with the tile's new index within its group.
    func dockEditable(id: String, group: DockEditor.Group?, zIndex: Double = 0, onDelete: (() -> Void)?,
                      onMove: @escaping (Int) -> Void = { _ in }) -> some View {
        modifier(EditableTile(id: id, group: group, restingZIndex: zIndex, onDelete: onDelete, onMove: onMove))
    }
}

private struct EditableTile: ViewModifier {
    let id: String
    let group: DockEditor.Group?
    /// Stacking order when not being dragged (a dragged tile always goes on top).
    let restingZIndex: Double
    let onDelete: (() -> Void)?
    let onMove: (Int) -> Void

    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    @State private var drag: CGSize = .zero

    private var editor: DockEditor { .shared }
    private var removeThreshold: CGFloat { -tileSize * 1.3 }
    private var willRemove: Bool { onDelete != nil && drag.height < removeThreshold }

    /// Neighbouring tiles swing in opposite directions, like iOS.
    private var direction: Double { id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0 ? 1 : -1 }

    private var angle: Double {
        guard editor.isEditing, drag == .zero else { return 0 }
        return (editor.wiggleTick ? 1.3 : -1.3) * direction
    }

    func body(content: Content) -> some View {
        let editing = editor.isEditing
        content
            // Measure before rotating so the wiggle doesn't trigger geometry updates.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("dock")) } action: {
                editor.frames[id] = $0
            }
            // While editing, a clear layer on top swallows taps/hover so nothing opens.
            .overlay {
                if editing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(moveGesture)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing, let onDelete {
                    let small = (editor.frames[id].map { Double($0.height) } ?? tileSize) < tileSize * 0.8
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: small ? 11 : 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(white: 0.35))
                            .background(Circle().fill(.white).padding(3))
                    }
                    .buttonStyle(.plain)
                    .offset(x: small ? -3 : -5, y: small ? -4 : -8)
                    .help("Remove")
                }
            }
            .overlay(alignment: .top) {
                if willRemove {
                    Text("Remove")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.red, in: .capsule)
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(y: -24)
                }
            }
            .rotationEffect(.degrees(angle))
            // Each swing eases to the next beat; leaving edit mode snaps straight (no animation).
            .animation(editing ? .easeInOut(duration: DockEditor.wiggleInterval) : nil, value: angle)
            .opacity(willRemove ? 0.5 : 1)
            .offset(drag)
            .zIndex(drag == .zero ? restingZIndex : 2)
            .onChange(of: editing) { _, _ in drag = .zero }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("dock"))
            .onChanged { value in
                guard group != nil || onDelete != nil else { return }
                drag = value.translation
            }
            .onEnded { value in
                defer { drag = .zero }
                if let onDelete, value.translation.height < removeThreshold {
                    onDelete()
                    return
                }
                guard let group, let start = editor.frames[id] else { return }
                let drop = CGPoint(x: start.midX + value.translation.width, y: start.midY + value.translation.height)
                onMove(editor.dropIndex(for: id, in: group, at: drop))
            }
    }
}

/// "Done" capsule shown at the end of the dock while editing.
struct EditDoneButton: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize

    var body: some View {
        Button { DockEditor.shared.end() } label: {
            Text("Done")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: tileSize * 0.55)
                .background(Color.accentColor, in: .capsule)
        }
        .buttonStyle(.plain)
        .shadow(radius: 3, y: 1)
    }
}
