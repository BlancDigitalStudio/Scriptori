import ScriptoriKit
import SwiftUI

/// Get-to-know-you onboarding: two intent questions → recommended books plus the full
/// library → "Your plan" → reading time tied to an everyday cue → pace → commit.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Step: Int, CaseIterable, Comparable {
        case welcome, intent, familiarity, book, plan, rhythm, pace

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @State private var step: Step = .welcome
    @State private var answers = OnboardingAnswers()
    @State private var versesPerCard = 2
    @State private var remindersEnabled = true
    @State private var reminderTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var isFinishing = false

    private static let cues: [(label: String, symbol: String, hour: Int, minute: Int)] = [
        ("With morning coffee", "cup.and.saucer.fill", 7, 30),
        ("On my commute", "tram.fill", 8, 0),
        ("On my lunch break", "fork.knife", 12, 30),
        ("Before bed", "moon.stars.fill", 21, 30),
    ]

    private var chosenBook: BibleBook? { model.book(id: answers.bookID) }

    private var palette: Palette {
        if step >= .plan, let chosenBook { return .named(chosenBook.palette) }
        return switch step {
        case .welcome, .intent: .dawn
        case .familiarity: .dusk
        case .book: .ocean
        default: .meadow
        }
    }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            VStack(spacing: 0) {
                if step != .welcome { topBar }
                Group {
                    switch step {
                    case .welcome: welcome
                    case .intent: intentStep
                    case .familiarity: familiarityStep
                    case .book: bookStep
                    case .plan: planStep
                    case .rhythm: rhythmStep
                    case .pace: paceStep
                    }
                }
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .foregroundStyle(palette.foreground)
        .animation(.snappy, value: step)
    }

    // MARK: Chrome

    private var questionSteps: [Step] { Array(Step.allCases.dropFirst()) }

    private var topBar: some View {
        HStack {
            Button { go(to: Step(rawValue: step.rawValue - 1)) } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel("Back")
            Spacer()
            Text("Step \(step.rawValue) of \(questionSteps.count)")
                .font(.footnote.weight(.semibold))
                .opacity(0.75)
            Spacer()
            Button("Skip") { skip() }
                .font(.subheadline.weight(.medium))
                .opacity(skipAvailable ? 0.8 : 0)
                .disabled(!skipAvailable)
                .frame(width: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var skipAvailable: Bool {
        switch step {
        case .intent, .familiarity, .book, .rhythm: true
        default: false
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let title = footerTitle {
            Button {
                advance()
            } label: {
                if isFinishing { ProgressView().tint(.black) } else { Text(title) }
            }
            .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
            .disabled(isFinishing)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var footerTitle: String? {
        switch step {
        case .welcome: "Get started"
        case .plan: "Looks good"
        case .rhythm: "Continue"
        case .pace: "Start my plan"
        case .intent, .familiarity, .book: nil
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.system(size: 54))
                .symbolEffect(.pulse)
            Text("From doomscroll\nto bloomscroll")
                .font(Typography.display(36))
            Text("Same swipe. Better feed. One chapter a day from a book you choose. First, a few questions so we can get to know you.")
                .opacity(0.75)
            Spacer()
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private var intentStep: some View {
        QuestionStep(title: "What brings you here?", subtitle: "We'll use this to suggest where to start.") {
            ForEach(ReadingIntent.allCases) { intent in
                OptionCard(title: intent.label, symbol: intent.symbol, isSelected: answers.intent == intent, foreground: palette.foreground) {
                    answers.intent = intent
                    go(to: .familiarity, after: 0.25)
                }
            }
        }
    }

    private var familiarityStep: some View {
        QuestionStep(title: "How familiar are you with the Bible?", subtitle: "No wrong answers. This just helps us pick a friendly first book.") {
            ForEach(BibleFamiliarity.allCases) { level in
                OptionCard(title: level.label, symbol: level.symbol, isSelected: answers.familiarity == level, foreground: palette.foreground) {
                    answers.familiarity = level
                    go(to: .book, after: 0.25)
                }
            }
        }
    }

    private var bookStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick your first book").font(Typography.display(30))
                    Text("You'll read it one chapter a day, in order. Tap a book to preview it.")
                        .opacity(0.75)
                }
                BookLibraryView(
                    books: model.books,
                    recommended: recommendations,
                    answers: answers,
                    foreground: palette.foreground
                ) { book in
                    answers.bookID = book.id
                    go(to: .plan, after: 0.35)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var planStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("YOUR PLAN")
                .font(.caption.weight(.semibold))
                .tracking(2)
                .opacity(0.7)
            if let book = chosenBook {
                BookCover(book: book, size: 84)
                Text(book.name).font(Typography.display(40))
                Text(planSentence(for: book))
                    .font(.title3)
                    .opacity(0.85)
                VStack(alignment: .leading, spacing: 12) {
                    planRow("book.pages", "\(book.chapterCount) chapter\(book.chapterCount == 1 ? "" : "s"), one a day")
                    planRow("clock", "About \(book.minutesPerDay) minutes a day")
                    planRow("sparkles", "A short reflection to finish each day")
                    planRow("flame.fill", "A streak that grows as you go")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 22))
            }
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }

    private var rhythmStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When will you read?").font(Typography.display(30))
                    Text("Tie it to something you already do every day. Habits stick better that way.")
                        .opacity(0.75)
                }
                VStack(spacing: 10) {
                    ForEach(Self.cues, id: \.label) { cue in
                        OptionCard(title: cue.label, symbol: cue.symbol, isSelected: answers.cue == cue.label, foreground: palette.foreground) {
                            answers.cue = cue.label
                            reminderTime = Calendar.current.date(bySettingHour: cue.hour, minute: cue.minute, second: 0, of: .now) ?? reminderTime
                        }
                    }
                }
                VStack(spacing: 12) {
                    Toggle("Daily reminder", isOn: $remindersEnabled)
                    if remindersEnabled {
                        DatePicker("Remind me at", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }
                .padding()
                .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 20))
                .tint(.orange)
                if remindersEnabled {
                    Text(reminderNote)
                        .font(.footnote)
                        .opacity(0.75)
                }
            }
            .padding(24)
        }
    }

    private var paceStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 54))
            Text("Read at your pace")
                .font(Typography.display(34))
            Text("Choose how many verses appear on each card. Change it anytime from the feed.")
                .opacity(0.75)
            VerseGroupingPicker(selection: versesPerCard, foreground: palette.foreground) { versesPerCard = $0 }
                .padding(.top, 8)
            Text("\(versesPerCard) verse\(versesPerCard == 1 ? "" : "s") per card")
                .font(.footnote)
                .opacity(0.7)
            Spacer()
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    // MARK: Helpers

    private var recommendations: [BibleBook] {
        model.recommendedBooks(for: answers)
    }

    private func planSentence(for book: BibleBook) -> String {
        if let intent = answers.intent {
            return "\(book.chapterCount) days with \(book.name), for \(intent.phrase)."
        }
        return "\(book.chapterCount) days with \(book.name), one chapter at a time."
    }

    private var reminderNote: String {
        let time = reminderTime.formatted(date: .omitted, time: .shortened)
        if let cue = answers.cue {
            return "One gentle nudge at \(time), \(cue.prefix(1).lowercased() + cue.dropFirst()). We'll ask for permission next."
        }
        return "One gentle nudge at \(time). We'll ask for permission next."
    }

    private func planRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).frame(width: 24)
        }
        .font(.body)
    }

    private func skip() {
        switch step {
        case .intent: go(to: .familiarity)
        case .familiarity: go(to: .book)
        case .book:
            answers.bookID = recommendations.first?.id ?? model.books.first?.id
            go(to: .plan)
        case .rhythm: advance()
        default: break
        }
    }

    private func advance() {
        switch step {
        case .welcome: go(to: .intent)
        case .plan: go(to: .rhythm)
        case .rhythm:
            Task {
                if remindersEnabled { await model.notifications.requestAuthorization() }
                go(to: .pace)
            }
        case .pace: finish()
        case .intent, .familiarity, .book: break
        }
    }

    private func go(to next: Step?, after delay: Double = 0) {
        guard let next else { return }
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            step = next
        }
    }

    private func finish() {
        isFinishing = true
        if answers.bookID == nil { answers.bookID = recommendations.first?.id }
        Task {
            await model.completeOnboarding(answers: answers, remindersEnabled: remindersEnabled, reminderTime: reminderTime, versesPerCard: versesPerCard)
        }
    }
}

private struct QuestionStep<Options: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var options: Options

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(Typography.display(30))
                    Text(subtitle).opacity(0.75)
                }
                VStack(spacing: 10) { options }
            }
            .padding(24)
            .padding(.top, 20)
        }
    }
}

/// Large single-tap answer used by the onboarding questions.
private struct OptionCard: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 32)
                Text(title).font(.headline)
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill") }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(foreground.opacity(isSelected ? 0.28 : 0.1), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(foreground.opacity(isSelected ? 0.6 : 0.15)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}