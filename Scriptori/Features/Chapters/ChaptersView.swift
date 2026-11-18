import ScriptoriKit
import SwiftUI

/// Every chapter the reader has checked in on, grouped by book with progress through each.
/// Opening one shows its verses to reread.
struct ChaptersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        NavigationStack {
            Group {
                if history.chapters.isEmpty {
                    ContentUnavailableView(
                        "No chapters yet",
                        systemImage: "book.pages",
                        description: Text("Chapters you finish and check in on will appear here.")
                    )
                } else {
                    List(history.startedBookIDs, id: \.self) { bookID in
                        let chapters = history.chapters.filter { $0.bookID == bookID }.sorted { $0.number > $1.number }
                        Section {
                            ForEach(chapters) { chapter in
                                NavigationLink(value: chapter.chapterID) {
                                    ChapterRow(chapter: chapter, entry: model.reflections.first { $0.id == chapter.entryID }, bookName: model.book(id: bookID)?.name ?? bookID)
                                }
                            }
                        } header: {
                            BookProgressHeader(book: model.book(id: bookID), bookID: bookID, read: chapters.count, isCurrent: model.profile?.plan.bookID == bookID)
                        }
                    }
                    .navigationDestination(for: String.self) { ChapterReaderView(chapterID: $0) }
                }
            }
            .navigationTitle("Chapters")
        }
    }
}

private struct ChapterRow: View {
    let chapter: ReadingHistory.CompletedChapter
    let entry: ReflectionEntry?
    let bookName: String

    var body: some View {
        HStack(spacing: 14) {
            Text("\(chapter.number)")
                .font(.headline.monospacedDigit())
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.15), in: .circle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(bookName) \(chapter.number)").font(.headline)
                Text(chapter.completedAt, format: .dateTime.weekday(.wide).month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let mood = entry?.mood {
                Image(systemName: mood.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(mood.label)
            }
        }
        .padding(.vertical, 4)
    }
}

struct BookProgressHeader: View {
    let book: BibleBook?
    let bookID: String
    let read: Int
    var isCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let book { BookCover(book: book, size: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(book?.name ?? bookID).font(.headline).foregroundStyle(.primary)
                        if isCurrent {
                            Text("Reading")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    if let book {
                        Text("\(read) of \(book.chapterCount) chapters read")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let book {
                ProgressView(value: Double(read), total: Double(book.chapterCount))
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }
}
