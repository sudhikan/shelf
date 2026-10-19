import SwiftUI

struct QuickNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var modified = Date.now

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? "New Note" : first
    }
}

/// Quick scratch notes, saved as JSON. "Send to Notes" copies one into Apple Notes.
@Observable
final class NotesStore {
    static let shared = NotesStore()
    private static let fileURL = URL.applicationSupportDirectory.appending(path: "Shelf/notes.json")

    var notes: [QuickNote] {
        didSet { save() }
    }
    var selectedID: UUID?

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([QuickNote].self, from: data), !saved.isEmpty {
            notes = saved
        } else {
            notes = [QuickNote()]
        }
        selectedID = notes.first?.id
    }

    private func save() {
        try? JSONEncoder().encode(notes).write(to: Self.fileURL, options: .atomic)
    }

    func newNote() {
        let note = QuickNote()
        notes.insert(note, at: 0)
        selectedID = note.id
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [QuickNote()] }
        if selectedID == id { selectedID = notes.first?.id }
    }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = .now
    }

    func sendToAppleNotes(_ note: QuickNote) {
        let html = note.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let escaped = html.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Notes\" to make new note with properties {body:\"\(escaped)\"}")?
            .executeAndReturnError(&error)
        if error == nil { NSWorkspace.shared.open(URL(filePath: "/System/Applications/Notes.app")) }
    }
}

struct NotesCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var store: NotesStore { .shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: tileSize * 0.36))
                .foregroundStyle(.yellow)
            if let note = store.notes.first, !note.text.isEmpty {
                Text(note.title)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .frame(width: tileSize * 1.5, alignment: .leading)
            }
        }
        .frame(minWidth: tileSize * 0.8)
    }
}

struct NotesExpanded: View {
    @FocusState private var editorFocused: Bool
    private var store: NotesStore { .shared }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Notes").font(.headline)
                    Spacer()
                    Button { store.newNote(); editorFocused = true } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .help("New Note")
                }
                .padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.notes) { note in
                            NoteListRow(note: note, selected: note.id == store.selectedID) {
                                store.selectedID = note.id
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 150)

            Divider()

            if let id = store.selectedID, let note = store.notes.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: Binding(get: { note.text }, set: { store.update(id, text: $0) }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                    HStack {
                        Text(note.modified, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { store.sendToAppleNotes(note) } label: { Image(systemName: "square.and.arrow.up") }
                            .help("Send to Apple Notes")
                            .disabled(note.text.isEmpty)
                        Button { store.delete(id) } label: { Image(systemName: "trash") }
                            .help("Delete Note")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
            }
        }
        .frame(width: 460, height: 320)
        .onAppear { editorFocused = true }
    }
}

private struct NoteListRow: View {
    let note: QuickNote
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(note.modified, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
