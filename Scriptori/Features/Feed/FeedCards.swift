import ScriptoriKit
import SwiftUI

struct ChapterIntroCard: View {
    let chapter: BibleChapter
    let palette: Palette

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("TODAY'S CHAPTER")
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(palette.secondaryForeground)
            Text(chapter.reference)
                .font(Typography.display(46))
            if let title = chapter.title {
                Text(title)
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(palette.secondaryForeground)
            }
            HStack(spacing: 16) {
                Label("\(chapter.verses.count) verses", systemImage: "text.alignleft")
                Label(chapter.translation, systemImage: "book")
            }
            .font(.footnote)
            .foregroundStyle(palette.secondaryForeground)
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .symbolEffect(.pulse, options: .repeating.speed(0.5))
                Text("Swipe up to begin")
                    .font(.footnote)
            }
            .foregroundStyle(palette.secondaryForeground)
            .padding(.bottom, 80)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 32)
    }
}

/// Second card: the (at most three) big ideas to watch for before reading.
struct ChapterThemesCard: View {
    let chapter: BibleChapter
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("IN THIS CHAPTER")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(palette.secondaryForeground)
                Text("Watch for these themes")
                    .font(Typography.display(30))
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(chapter.reflection.themes) { theme in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: theme.symbol)
                            .font(.title2)
                            .foregroundStyle(palette.accent)
                            .frame(width: 48, height: 48)
                            .background(palette.foreground.opacity(0.1), in: .circle)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(theme.title).font(.headline)
                                if let verse = theme.keyVerse {
                                    Text("v. \(verse)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.secondaryForeground)
                                }
                            }
                            Text(theme.summary)
                                .font(.subheadline)
                                .foregroundStyle(palette.secondaryForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Text("Swipe up to read")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryForeground)
                Spacer()
            }
            .padding(.bottom, 80)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 28)
        .padding(.top, 100)
    }
}

/// Pause card in long chapters: recaps the stretch just read and offers a quick note,
/// so there's something to come back to when it's time to reflect.
struct CheckpointCard: View {
    let chapter: BibleChapter
    let checkpoint: Checkpoint
    let markedVerses: [BibleVerse]
    let palette: Palette
    let note: String
    let onNoteChange: (String) -> Void

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("PAUSE & RECAP", systemImage: "pause.circle")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(palette.secondaryForeground)
                Text("So far: verses \(checkpoint.fromVerse)–\(checkpoint.throughVerse)")
                    .font(Typography.display(28))
            }
            if markedVerses.isEmpty {
                Text("Nothing marked in this stretch. Tap the bookmark on any card to save a verse for your reflection.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryForeground)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You marked").font(.subheadline.weight(.semibold))
                    ForEach(markedVerses.prefix(3)) { verse in
                        Text("\(verse.number)  \(verse.text)")
                            .font(.system(.subheadline, design: .serif))
                            .lineLimit(2)
                    }
                    if markedVerses.count > 3 {
                        Text("+ \(markedVerses.count - 3) more")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryForeground)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("In a few words, what's happening?").font(.subheadline.weight(.semibold))
                TextField("Optional note for later", text: $draft)
                    .focused($isEditing)
                    .submitLabel(.done)
                    .padding(14)
                    .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 16))
                    .tint(palette.accent)
                    .onChange(of: isEditing) { _, editing in
                        if !editing { onNoteChange(draft) }
                    }
                    .onSubmit { isEditing = false }
            }
            Spacer()
            HStack {
                Spacer()
                Text("Swipe up to keep reading")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryForeground)
                Spacer()
            }
            .padding(.bottom, 80)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 28)
        .padding(.top, 100)
        // The feed ignores the keyboard so card heights never change; lift this card instead.
        .offset(y: isEditing ? -160 : 0)
        .animation(.snappy, value: isEditing)
        .onAppear { draft = note }
        .onDisappear { if draft != note { onNoteChange(draft) } }
    }
}

/// Final card in the feed: a one-tap mood check-in that opens the guided reflection.
struct ReflectionPromptCard: View {
    let chapter: BibleChapter
    let isCompleted: Bool
    let streak: Int
    let palette: Palette
    var todaysEntry: ReflectionEntry?
    /// An unfinished check-in, whose picks are shown so the reader can carry on.
    var draft: ReflectionEntry?
    /// e.g. "Philippians 3", shown once today is complete.
    var upNext: String?
    var isBookFinished = false
    let onMoodSelected: (Mood) -> Void
    var onEdit: (ReflectionEntry) -> Void = { _ in }
    var onChooseBook: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if isCompleted {
                completed
            } else {
                checkIn
            }
            Spacer()
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 28)
        .multilineTextAlignment(.center)
    }

    private var checkIn: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(palette.accent)
            Text("You finished \(chapter.reference)")
                .font(Typography.display(30))
            Text("How are you feeling after today's reading?")
                .font(.body)
                .foregroundStyle(palette.secondaryForeground)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Mood.allCases) { mood in
                    let isSelected = draft?.mood == mood
                    Button { onMoodSelected(mood) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: mood.symbol)
                                .font(.system(size: 26))
                                .foregroundStyle(palette.accent)
                                .frame(height: 30)
                            Text(mood.label).font(.caption.weight(isSelected ? .bold : .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(palette.foreground.opacity(isSelected ? 0.28 : 0.1), in: .rect(cornerRadius: 18))
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 18).strokeBorder(palette.accent, lineWidth: 2)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.accent)
                                    .padding(6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            if let draft, let mood = draft.mood {
                draftSummary(draft, mood: mood)
            } else {
                Text("Reflect to complete today and grow your streak")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryForeground)
            }
        }
    }

    private func draftSummary(_ draft: ReflectionEntry, mood: Mood) -> some View {
        VStack(spacing: 12) {
            if !draft.takeaways.isEmpty {
                Text(draft.takeaways.joined(separator: " · "))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.secondaryForeground)
            }
            if let answer = draft.answers.first(where: { !$0.text.isEmpty }) {
                Text(answer.text)
                    .font(.system(.footnote, design: .serif))
                    .lineLimit(2)
                    .foregroundStyle(palette.secondaryForeground)
            }
            Button("Continue your reflection", systemImage: "arrow.right") { onMoodSelected(mood) }
                .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
        }
    }

    private var completed: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundStyle(palette.accent)
                .symbolEffect(.bounce, value: isCompleted)
            Text("Today is complete")
                .font(Typography.display(30))
            StreakBadge(count: streak)
            if let todaysEntry {
                entryPreview(todaysEntry)
            }
            if isBookFinished {
                Text("That was the last chapter of \(chapter.book). Pick what you'd like to read next.")
                    .font(.body)
                    .foregroundStyle(palette.secondaryForeground)
                Button("Choose your next book", systemImage: "books.vertical", action: onChooseBook)
                    .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
            } else if let upNext {
                Text("Up next tomorrow: \(upNext)")
                    .font(.body)
                    .foregroundStyle(palette.secondaryForeground)
            } else {
                Text("A new chapter blooms tomorrow. Your reflection is saved in your Journal.")
                    .font(.body)
                    .foregroundStyle(palette.secondaryForeground)
            }
        }
    }

    private func entryPreview(_ entry: ReflectionEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let mood = entry.mood {
                    Label(mood.label, systemImage: mood.symbol)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Button("Edit", systemImage: "pencil") { onEdit(entry) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
            }
            if !entry.takeaways.isEmpty {
                Text(entry.takeaways.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryForeground)
            }
            if let firstAnswer = entry.answers.first(where: { !$0.text.isEmpty }) {
                Text(firstAnswer.text)
                    .font(.system(.subheadline, design: .serif))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 20))
    }
}
