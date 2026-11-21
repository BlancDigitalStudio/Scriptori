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
                            ForEach(group.chapters) { chapter in
                                // A chapter reflected on once goes straight to its entry; one read
                                // again opens the list of its entries.
                                if let only = chapter.entries.first, chapter.entries.count == 1 {
                                    NavigationLink(value: only.id) { JournalChapterRow(chapter: chapter) }
                                } else {
                                    NavigationLink(value: chapter.chapterID) { JournalChapterRow(chapter: chapter) }
                                }
                            }
                        } header: {
                            JournalBookHeader(book: model.book(id: group.bookID), fallbackName: group.chapters[0].reference, count: group.entryCount)
                        }
                    }
                    .navigationDestination(for: UUID.self) { JournalDetailView(entryID: $0) }
                    .navigationDestination(for: String.self) { JournalChapterView(chapterID: $0) }
                }
            }
            .navigationTitle("Journal")
        }
    }

    /// The most recently reflected-on book first; within it, chapters by their latest entry.
    private var bookGroups: [JournalBookGroup] {
        JournalBookGroup.groups(from: model.reflections)
    }
}

/// A chapter's journal entries, newest first: more than one when the chapter was read again.
private struct JournalChapterGroup: Identifiable {
    let chapterID: String
    let reference: String
    let entries: [ReflectionEntry]

    var id: String { chapterID }
    var latest: ReflectionEntry { entries[0] }
}

private struct JournalBookGroup {
    let bookID: String
    let chapters: [JournalChapterGroup]

    var entryCount: Int { chapters.reduce(0) { $0 + $1.entries.count } }

    static func groups(from reflections: [ReflectionEntry]) -> [JournalBookGroup] {
        let sorted = reflections.sorted { $0.createdAt > $1.createdAt }
        var bookOrder: [String] = []
        var chapterOrder: [String: [String]] = [:]
        var entries: [String: [ReflectionEntry]] = [:]
        for entry in sorted {
            let bookID = ChapterID.parse(entry.chapterID)?.bookID ?? entry.chapterID
            if chapterOrder[bookID] == nil { bookOrder.append(bookID) }
            if entries[entry.chapterID] == nil { chapterOrder[bookID, default: []].append(entry.chapterID) }
            entries[entry.chapterID, default: []].append(entry)
        }
        return bookOrder.map { bookID in
            JournalBookGroup(bookID: bookID, chapters: (chapterOrder[bookID] ?? []).compactMap { chapterID in
                guard let list = entries[chapterID], let first = list.first else { return nil }
                return JournalChapterGroup(chapterID: chapterID, reference: first.chapterReference, entries: list)
            })
        }
    }
}

/// Every journal entry for one chapter, newest first.
private struct JournalChapterView: View {
    @Environment(AppModel.self) private var model
    let chapterID: String

    private var entries: [ReflectionEntry] {
        model.reflections.filter { $0.chapterID == chapterID }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let entries = entries
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.id) { JournalEntryRow(entry: entry) }
                }
            } footer: {
                Text("You've reflected on this chapter \(entries.count) times.")
            }
        }
        .navigationTitle(entries.first?.chapterReference ?? model.book(id: ChapterID.parse(chapterID)?.bookID)?.name ?? "Chapter")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty { ContentUnavailableView("No entries", systemImage: "book.closed") }
        }
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

/// A chapter in the journal: its name, when it was last reflected on, and how many entries it has.
private struct JournalChapterRow: View {
    let chapter: JournalChapterGroup

    var body: some View {
        let latest = chapter.latest
        HStack(spacing: 14) {
            Image(systemName: latest.mood?.symbol ?? "book.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.reference).font(.headline)
                Text(latest.createdAt, format: .dateTime.weekday(.wide).month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if chapter.entries.count == 1, !latest.takeaways.isEmpty {
                    Text(latest.takeaways.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if chapter.entries.count > 1 {
                Text("\(chapter.entries.count) entries")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
            }
            if chapter.entries.contains(where: { $0.syncState == .pending }) {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary).accessibilityLabel("Not yet synced")
            }
        }
        .padding(.vertical, 4)
    }
}

/// One entry in a chapter's list, titled by the day it was written.
private struct JournalEntryRow: View {
    let entry: ReflectionEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.mood?.symbol ?? "book.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.createdAt, format: .dateTime.weekday(.wide).month().day().year())
                    .font(.headline)
                Text(entry.createdAt, format: .dateTime.hour().minute())
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

struct JournalDetailView: View {
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
                        // A plain row: a `Label` inside `LabeledContent` left a large empty gap here.
                        HStack(spacing: 8) {
                            Text("Mood")
                            Spacer()
                            Image(systemName: mood.symbol).foregroundStyle(.tint)
                            Text(mood.label).foregroundStyle(.secondary)
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
                            // The picked option, drawn like the selected chip in the reflection.
                            Text(choice)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.brandTint, in: .capsule)
                                .foregroundStyle(.white)
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
