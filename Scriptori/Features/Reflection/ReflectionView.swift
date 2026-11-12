import ScriptoriKit
import SwiftUI

/// End-of-chapter flow: mood + key takeaway (one tap each) → guided questions → celebration.
/// Also used to edit a saved entry from the Journal or the Today tab.
struct ReflectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case new
        case edit
    }

    let chapter: BibleChapter
    let palette: Palette
    private let mode: Mode
    /// Quick notes from checkpoint cards, shown alongside marked verses while writing.
    private let notes: [(throughVerse: Int, text: String)]

    @State private var entry: ReflectionEntry
    @State private var step = 0
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var result: CompletionResult?
    @State private var showReread = false
    @FocusState private var isEditing: Bool

    /// Starts a check-in, picking up an unfinished `draft` for this chapter if there is one.
    init(chapter: BibleChapter, session: ChapterSession, draft: ReflectionEntry?, initialMood: Mood?, palette: Palette) {
        self.chapter = chapter
        self.palette = palette
        self.mode = .new
        self.notes = session.progress.orderedNotes
        var entry = ReflectionEntry(chapter: chapter, day: session.progress.day, mood: initialMood)
        if let draft, draft.chapterID == chapter.id, draft.day == session.progress.day {
            entry = draft
            entry.mood = initialMood ?? draft.mood
        }
        entry.highlights = session.progress.markedVerses
        _entry = State(initialValue: entry)
    }

    init(editing existing: ReflectionEntry, chapter: BibleChapter, palette: Palette) {
        self.chapter = chapter
        self.palette = palette
        self.mode = .edit
        self.notes = []
        _entry = State(initialValue: existing)
    }

    private var questionCount: Int { entry.answers.count }
    private var totalSteps: Int { questionCount + 1 }
    private var isLastStep: Bool { step == totalSteps - 1 }
    private var highlightedVerses: [BibleVerse] { chapter.verses.filter { entry.highlights.contains($0.number) } }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            if let result {
                CompletionCelebrationView(result: result, palette: palette) { dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                flow
            }
        }
        .foregroundStyle(palette.foreground)
        .interactiveDismissDisabled(isSubmitting || result != nil)
        .presentationDetents([.large])
        .presentationCornerRadius(32)
        .onDisappear {
            if mode == .new, result == nil { model.saveReflectionDraft(entry) }
        }
        .sheet(isPresented: $showReread) {
            RereadSheet(chapter: chapter, highlights: entry.highlights, palette: palette) { verse in
                insertQuote(verse)
                showReread = false
            }
        }
    }

    private var flow: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    if step == 0 {
                        checkInStep
                    } else {
                        questionStep(index: step - 1)
                    }
                }
                .padding(24)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .scrollDismissesKeyboard(.interactively)
            footer
        }
    }

    private var header: some View {
        HStack {
            Button {
                if step > 0 { withAnimation(.snappy) { step -= 1 } } else { dismiss() }
            } label: {
                Image(systemName: step > 0 ? "chevron.left" : "xmark")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel(step > 0 ? "Back" : "Close")
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(palette.foreground.opacity(index <= step ? 0.95 : 0.25))
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: step)
            Spacer()
            Button { showReread = true } label: {
                Image(systemName: "book")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel("Re-read \(chapter.reference)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: Step 1 – micro check-in

    private var checkInStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode == .edit ? "Edit reflection" : "Check in")
                    .font(Typography.display(30))
                Text(mode == .edit ? "\(entry.chapterReference) · \(entry.day.startDate().formatted(date: .abbreviated, time: .omitted))" : "Two taps, then a couple of short questions.")
                    .foregroundStyle(palette.secondaryForeground)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("How do you feel?").font(.headline)
                FlowLayout(spacing: 8) {
                    ForEach(Mood.allCases) { mood in
                        Chip(title: mood.label, symbol: mood.symbol, isSelected: entry.mood == mood, tint: palette.foreground) {
                            entry.mood = mood
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Key takeaway").font(.headline)
                Text("Pick up to 2 themes that stood out.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryForeground)
                FlowLayout(spacing: 8) {
                    ForEach(takeawayOptions, id: \.self) { tag in
                        Chip(title: tag, isSelected: entry.takeaways.contains(tag), tint: palette.foreground) {
                            toggleTakeaway(tag)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chapter's options, plus anything saved earlier that's no longer offered.
    private var takeawayOptions: [String] {
        let options = chapter.reflection.takeawayOptions
        return options + entry.takeaways.filter { !options.contains($0) }
    }

    // MARK: Guided questions

    private func questionStep(index: Int) -> some View {
        let answer = entry.answers[index]
        let choices = chapter.reflection.questions.first { $0.id == answer.questionID }?.choices ?? []
        let cited = chapter.citedVerses(in: answer.prompt)
        return VStack(alignment: .leading, spacing: 20) {
            Text("Question \(index + 1) of \(questionCount)")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(palette.secondaryForeground)
            Text(answer.prompt)
                .font(Typography.display(26))
                .fixedSize(horizontal: false, vertical: true)

            if !cited.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cited) { verse in
                        Text("\(verse.number)  \(verse.text)")
                            .font(.system(.subheadline, design: .serif))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(0.08), in: .rect(cornerRadius: 16))
                .overlay(alignment: .leading) {
                    Capsule().fill(palette.accent).frame(width: 3).padding(.vertical, 10)
                }
            }

            if !choices.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(choices, id: \.self) { choice in
                        Chip(title: choice, isSelected: entry.answers[index].choice == choice, tint: palette.foreground) {
                            entry.answers[index].choice = entry.answers[index].choice == choice ? nil : choice
                        }
                    }
                }
            }

            TextField(choices.isEmpty ? "Write a few words…" : "Add a thought (optional)", text: $entry.answers[index].text, axis: .vertical)
                .lineLimit(3...8)
                .focused($isEditing)
                .padding(16)
                .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 18))
                .tint(palette.accent)

            memoryAids
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the reader marked and noted while reading, so long chapters are easy to recall.
    @ViewBuilder
    private var memoryAids: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(highlightedVerses.isEmpty && notes.isEmpty ? "Need a reminder?" : "Your highlights")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showReread = true
                } label: {
                    Label("Re-read", systemImage: "book")
                        .font(.subheadline.weight(.medium))
                }
            }
            if !highlightedVerses.isEmpty || !notes.isEmpty {
                Text("Tap one to quote it in your answer.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryForeground)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(highlightedVerses) { verse in
                            aidCard(label: "v. \(verse.number)", text: verse.text, symbol: "bookmark.fill") { insertQuote(verse) }
                        }
                        ForEach(notes, id: \.throughVerse) { note in
                            aidCard(label: "Note · to v. \(note.throughVerse)", text: note.text, symbol: "pencil") { insert(note.text) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 4)
    }

    private func aidCard(label: String, text: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Text(text)
                    .font(.system(.footnote, design: .serif))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(width: 200, alignment: .topLeading)
            .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                advance()
            } label: {
                if isSubmitting {
                    ProgressView().tint(.black)
                } else {
                    Text(isLastStep ? (mode == .edit ? "Save changes" : "Complete today") : "Continue")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
            .disabled(!canAdvance || isSubmitting)
            .opacity(canAdvance ? 1 : 0.5)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var canAdvance: Bool {
        if step == 0 { return entry.mood != nil }
        if isLastStep { return entry.isSubmittable }
        return true
    }

    private func toggleTakeaway(_ tag: String) {
        if let index = entry.takeaways.firstIndex(of: tag) {
            entry.takeaways.remove(at: index)
        } else if entry.takeaways.count < 2 {
            entry.takeaways.append(tag)
        } else {
            entry.takeaways = [entry.takeaways[1], tag]
        }
    }

    // MARK: Quoting

    private func insertQuote(_ verse: BibleVerse) {
        let words = verse.text.split(separator: " ")
        let snippet = words.prefix(14).joined(separator: " ") + (words.count > 14 ? "…" : "")
        insert("\u{201C}\(snippet)\u{201D} (v. \(verse.number))")
    }

    private func insert(_ text: String) {
        let index = max(step - 1, 0)
        guard entry.answers.indices.contains(index) else { return }
        if step == 0 { withAnimation(.snappy) { step = 1 } }
        let current = entry.answers[index].text
        entry.answers[index].text = current.isEmpty ? text + " " : current + (current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : "\n") + text + " "
    }

    // MARK: Submit

    private func advance() {
        isEditing = false
        guard isLastStep else {
            withAnimation(.snappy) { step += 1 }
            return
        }
        isSubmitting = true
        errorText = nil
        Task {
            defer { isSubmitting = false }
            if mode == .edit {
                await model.updateReflection(entry)
                dismiss()
                return
            }
            do {
                let completed = try await model.submitReflection(entry)
                withAnimation(.spring(duration: 0.5)) { result = completed }
                if completed == nil { dismiss() }
            } catch let error as CompletionError {
                errorText = switch error {
                case .versesNotFinished: "Finish every verse card first, then come back to reflect."
                case .reflectionIncomplete: "Answer at least one question to complete today."
                case .alreadyCompletedToday: "You've already completed today's chapter."
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// The whole chapter in compact form, for refreshing your memory mid-reflection.
private struct RereadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let chapter: BibleChapter
    let highlights: [Int]
    let palette: Palette
    let onQuote: (BibleVerse) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapter.verses) { verse in
                    let isMarked = highlights.contains(verse.number)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(verse.number)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        Text(verse.text)
                            .font(.system(.body, design: .serif))
                        if isMarked {
                            Spacer(minLength: 0)
                            Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                        }
                    }
                    .listRowBackground(isMarked ? Color.orange.opacity(0.12) : nil)
                    .swipeActions(edge: .trailing) {
                        Button("Quote") { onQuote(verse) }.tint(.indigo)
                    }
                    .contextMenu {
                        Button("Quote in my answer", systemImage: "text.quote") { onQuote(verse) }
                    }
                    .id(verse.number)
                }
                .listStyle(.plain)
                .onAppear {
                    if let first = highlights.first { proxy.scrollTo(first, anchor: .top) }
                }
            }
            .navigationTitle(chapter.reference)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Text("Swipe or long-press a verse to quote it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
