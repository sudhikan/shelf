import SwiftUI

struct ClipboardCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var service: ClipboardService { .shared }

    var body: some View {
        Image(systemName: service.isPaused ? "clipboard" : "doc.on.clipboard")
            .font(.system(size: tileSize * 0.42, weight: .light))
            .frame(width: tileSize * 0.8)
            .onAppear { service.start() }
    }
}

struct ClipboardExpanded: View {
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var service: ClipboardService { .shared }

    private var filtered: [ClipItem] {
        let base = query.isEmpty ? service.items
            : service.items.filter { $0.preview.localizedCaseInsensitiveContains(query) }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Clipboard", symbol: "doc.on.clipboard") {
                Menu {
                    Toggle("Pause Recording", isOn: Binding(get: { service.isPaused }, set: { service.isPaused = $0 }))
                    Divider()
                    Button("Clear History (Keeps Pinned)", role: .destructive) { service.clearUnpinned() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = filtered.first { pick(first) } }

            if filtered.isEmpty {
                Text(service.items.isEmpty ? "Copy something and it will appear here." : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered.prefix(100)) { item in
                            ClipRow(item: item) { pick(item) }
                        }
                    }
                }
                .frame(height: 340)
            }
            Text("Click an item to copy it, then press ⌘V.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            service.start()
            searchFocused = true
        }
    }

    private func pick(_ item: ClipItem) {
        service.copy(item)
        dismiss()
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let action: () -> Void
    @State private var hovering = false
    private var service: ClipboardService { .shared }

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering || item.pinned {
                Button { service.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
            }
            if hovering {
                Button { service.delete(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .image:
            if let image = service.image(for: item) {
                Image(nsImage: image).resizable().scaledToFill().clipShape(.rect(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
        case .files:
            if let first = item.filePaths?.first {
                Image(nsImage: IconCache.icon(for: first)).resizable()
            }
        case .url:
            Image(systemName: "link").foregroundStyle(.blue)
        case .text:
            if let id = item.sourceBundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: IconCache.icon(for: url.path(percentEncoded: false))).resizable()
            } else {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            }
        }
    }
}
