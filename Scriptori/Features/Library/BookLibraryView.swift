import ScriptoriKit
import SwiftUI

/// Small gradient tile standing in for a book cover.
struct BookCover: View {
    let book: BibleBook
    var size: CGFloat = 52

    var body: some View {
        let palette = Palette.named(book.palette)
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(palette.gradient)
            .overlay {
                Text(book.id.prefix(3).capitalized)
                    .font(.system(size: size * 0.3, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.foreground)
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.white.opacity(0.2)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct BookCard: View {
    let book: BibleBook
    var reason: String?
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                BookCover(book: book)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.name).font(.headline)
                    if let reason {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(foreground.opacity(0.85))
                    }
                    Text(book.lengthSummary)
                        .font(.caption)
                        .foregroundStyle(foreground.opacity(0.65))
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.5)
            }
            .padding(14)
            .background(foreground.opacity(0.1), in: .rect(cornerRadius: 20))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
    }
}

extension BibleBook {
    var lengthSummary: String {
        "\(chapterCount) chapter\(chapterCount == 1 ? "" : "s") · about \(minutesPerDay) min a day"
    }

    func reason(for answers: OnboardingAnswers?) -> String? {
        if let intent = answers?.intent, intents.contains(intent) {
            return "Fits \(intent.phrase)"
        }
        if answers?.familiarity == .new, level == 1 { return "A great first book" }
        return nil
    }
}

/// Searchable list of every book, with optional recommendations on top.
/// Tapping a book opens its preview; starting it calls `onStart`.
struct BookLibraryView: View {
    let books: [BibleBook]
    var recommended: [BibleBook] = []
    var answers: OnboardingAnswers?
    var foreground: Color = .white
    var startNote: String?
    let onStart: (BibleBook) -> Void

    @State private var query = ""
    @State private var previewing: BibleBook?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
            if query.isEmpty, !recommended.isEmpty {
                sectionHeader("Recommended for you")
                ForEach(recommended) { book in
                    BookCard(book: book, reason: book.reason(for: answers), foreground: foreground) { previewing = book }
                }
                sectionHeader("Browse all \(books.count) books")
                    .padding(.top, 12)
            }
            searchField
            ForEach(groups, id: \.title) { group in
                sectionHeader(group.title)
                    .padding(.top, 8)
                ForEach(group.books) { book in
                    BookCard(book: book, foreground: foreground) { previewing = book }
                }
            }
            if groups.isEmpty {
                Text("No books match \"\(query)\"")
                    .foregroundStyle(foreground.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
        }
        .sheet(item: $previewing) { book in
            BookPreviewView(book: book, startNote: startNote) {
                previewing = nil
                onStart(book)
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").opacity(0.6)
            TextField("Search books", text: $query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.6) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .background(foreground.opacity(0.1), in: .rect(cornerRadius: 14))
        .foregroundStyle(foreground)
        .tint(foreground)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(foreground.opacity(0.65))
    }

    private var groups: [(title: String, books: [BibleBook])] {
        let filtered = query.isEmpty ? books : books.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
        var result: [(title: String, books: [BibleBook])] = []
        for book in filtered {
            let title = "\(book.testament.label) · \(book.category)"
            if result.last?.title == title {
                result[result.count - 1].books.append(book)
            } else {
                result.append((title, [book]))
            }
        }
        return result
    }
}

struct BookPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let book: BibleBook
    var startNote: String?
    let onStart: () -> Void

    @State private var sample: (verse: BibleVerse, reference: String)?

    var body: some View {
        let palette = Palette.named(book.palette)
        ZStack {
            PaletteBackground(palette: palette)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .accessibilityLabel("Close")
                }
                .padding([.horizontal, .top], 20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        BookCover(book: book, size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.name).font(Typography.display(36))
                            Text("\(book.testament.label) · \(book.category)")
                                .foregroundStyle(palette.secondaryForeground)
                        }
                        Text(book.blurb).font(.body)
                        HStack(spacing: 16) {
                            Label("\(book.chapterCount) chapters", systemImage: "book.pages")
                            Label("~\(book.minutesPerDay) min a day", systemImage: "clock")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.secondaryForeground)
                        if !book.themes.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(book.themes, id: \.self) { theme in
                                    Text(theme)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(palette.foreground.opacity(0.12), in: .capsule)
                                }
                            }
                        }
                        if let sample {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\u{201C}\(sample.verse.text)\u{201D}")
                                    .font(.system(.title3, design: .serif).italic())
                                Text(sample.reference)
                                    .font(.caption.weight(.semibold))
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                                    .foregroundStyle(palette.secondaryForeground)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 20))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 10) {
                    if let startNote {
                        Text(startNote)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryForeground)
                            .multilineTextAlignment(.center)
                    }
                    Button(startLabel, action: onStart)
                        .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .foregroundStyle(palette.foreground)
        .presentationCornerRadius(32)
        .task { sample = await model.sampleVerse(for: book) }
    }

    private var startLabel: String {
        guard let plan = model.profile?.plan else { return "Start with \(book.name)" }
        if plan.bookID == book.id { return "Keep reading \(book.name)" }
        if let resume = plan.resumePosition(for: book.id, chapterCount: book.chapterCount) {
            return "Continue at chapter \(resume + 1)"
        }
        return "Start \(book.name) now"
    }
}

/// Pushed from Profile to switch books.
struct ChangeBookScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PaletteBackground(palette: .dawn)
            ScrollView {
                BookLibraryView(
                    books: model.books,
                    recommended: model.recommendedBooks(excluding: model.profile?.plan.bookID),
                    answers: model.profile?.onboarding,
                    startNote: "Opens on the Today tab, ready to read. Your streak and journal stay as they are, and switching back picks up where you left off."
                ) { book in
                    Task {
                        await model.chooseBook(book.id)
                        dismiss()
                    }
                }
                .padding(20)
            }
        }
        .foregroundStyle(.white)
        .navigationTitle("Change book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Shown on the Today tab when there's no chapter to serve: before the first book is
/// chosen, or after the current book is finished.
struct BookChoiceView: View {
    @Environment(AppModel.self) private var model
    let reason: AppModel.BookChoice

    var body: some View {
        ZStack {
            PaletteBackground(palette: .dawn)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    BookLibraryView(
                        books: model.books,
                        recommended: model.recommendedBooks(excluding: finishedBookID),
                        answers: model.profile?.onboarding
                    ) { book in
                        Task { await model.chooseBook(book.id) }
                    }
                }
                .padding(24)
                .padding(.top, 20)
            }
        }
        .foregroundStyle(.white)
    }

    private var finishedBookID: String? {
        if case .finished(let book) = reason { return book.id }
        return nil
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch reason {
            case .firstBook:
                Image(systemName: "books.vertical.fill").font(.system(size: 36))
                Text("Choose your book").font(Typography.display(34))
                Text("You'll read one chapter a day, in order. You can change books anytime from Profile.")
                    .opacity(0.75)
            case .finished(let book):
                Image(systemName: "checkmark.seal.fill").font(.system(size: 36))
                Text("You finished \(book.name)").font(Typography.display(34))
                Text("All \(book.chapterCount) chapters, one day at a time. Where would you like to go next?")
                    .opacity(0.75)
            }
        }
    }
}
