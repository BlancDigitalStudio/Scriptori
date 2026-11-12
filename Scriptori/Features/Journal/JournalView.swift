import ScriptoriKit
import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.reflections.isEmpty {
                    ContentUnavailableView(
                        "Your journal is empty",
                        systemImage: "book.closed",
                        description: Text("Finish today's chapter and reflect to add your first entry.")
                    )
                } else {
                    List(bookGroups, id: \.bookID) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                NavigationLink(value: entry.id) {
                                    JournalRow(entry: entry)
                                }
                            }
                        } header: {
                            JournalBookHeader(book: model.book(id: group.bookID), fallbackName: group.entries[0].chapterReference, count: group.entries.count)
                        }
                    }
                    .navigationDestination(for: UUID.self) { JournalDetailView(entryID: $0) }
                }
            }
            .navigationTitle("Journal")
        }
    }

    /// Entries grouped by book: the most recently reflected-on book first, newest entries first.
    private var bookGroups: [(bookID: String, entries: [ReflectionEntry])] {
        let sorted = model.reflections.sorted { $0.createdAt > $1.createdAt }
        var order: [String] = []
        var groups: [String: [ReflectionEntry]] = [:]
        for entry in sorted {
            let bookID = ChapterID.parse(entry.chapterID)?.bookID ?? entry.chapterID
            if groups[bookID] == nil { order.append(bookID) }
            groups[bookID, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

private struct JournalBookHeader: View {
    let book: BibleBook?
    let fallbackName: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            if let book { BookCover(book: book, size: 24) }
            Text(book?.name ?? fallbackName)
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer()
            Text("\(count) \(count == 1 ? "entry" : "entries")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

private struct JournalRow: View {
    let entry: ReflectionEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.mood?.symbol ?? "book.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.chapterReference).font(.headline)
                Text(entry.createdAt, format: .dateTime.weekday(.wide).month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !entry.takeaways.isEmpty {
                    Text(entry.takeaways.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.syncState == .pending {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary).accessibilityLabel("Not yet synced")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct JournalDetailView: View {
    @Environment(AppModel.self) private var model
    let entryID: UUID

    @State private var chapter: BibleChapter?
    @State private var isEditing = false

    private var entry: ReflectionEntry? { model.reflections.first { $0.id == entryID } }

    var body: some View {
        if let entry {
            List {
                Section {
                    if let mood = entry.mood {
                        LabeledContent("Mood") {
                            Label(mood.label, systemImage: mood.symbol)
                        }
                    }
                    if !entry.takeaways.isEmpty {
                        LabeledContent("Key takeaways", value: entry.takeaways.joined(separator: ", "))
                    }
                    if let updatedAt = entry.updatedAt {
                        LabeledContent("Edited", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                ForEach(entry.answers.filter(\.isAnswered), id: \.questionID) { answer in
                    Section(answer.prompt) {
                        if let choice = answer.choice {
                            Label(choice, systemImage: "checkmark.circle.fill")
                        }
                        if !answer.text.isEmpty {
                            Text(answer.text)
                        }
                    }
                }
                if let chapter, !entry.highlights.isEmpty {
                    Section("Verses you marked") {
                        ForEach(chapter.verses.filter { entry.highlights.contains($0.number) }) { verse in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(verse.number)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(verse.text).font(.system(.body, design: .serif))
                            }
                        }
                    }
                }
            }
            .navigationTitle(entry.chapterReference)
            .toolbar {
                Button("Edit") { isEditing = true }
                    .disabled(chapter == nil)
            }
            .sheet(isPresented: $isEditing) {
                if let chapter {
                    ReflectionView(editing: entry, chapter: chapter, palette: .named(chapter.palette))
                }
            }
            .task { chapter = await model.chapter(id: entry.chapterID) }
        } else {
            ContentUnavailableView("Entry not found", systemImage: "book.closed")
        }
    }
}
