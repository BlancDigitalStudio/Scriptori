import ScriptoriKit
import SwiftUI

/// Full-screen vertical "bloomscroll" feed for today's chapter:
/// intro card → themes card → verse cards (1–3 verses each, with checkpoints in long
/// chapters) → reflection card.
struct ScriptoriFeedView: View {
    @Environment(AppModel.self) private var model
    @State private var sharePage: VersePage?
    @State private var reflectionMood: Mood?
    @State private var editingEntry: ReflectionEntry?
    @State private var showBookPicker = false

    var body: some View {
        if let today = model.today, let profile = model.profile {
            feed(today: today, profile: profile)
        } else if let reason = model.bookChoice {
            BookChoiceView(reason: reason)
        } else {
            LaunchView()
        }
    }

    private func feed(today: TodayContext, profile: UserProfile) -> some View {
        let session = today.session
        let palette = Palette.named(today.chapter.palette)
        let prefs = profile.preferences

        return ZStack {
            PaletteBackground(palette: palette)

            CardPager(
                items: session.items,
                focusedID: session.focusedItemID,
                onFocus: { session.focus(on: $0) }
            ) { item in
                card(for: item, today: today, palette: palette, prefs: prefs)
            }
            .ignoresSafeArea(edges: .top)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: session.focusedItemID)

            VStack(spacing: 0) {
                FeedHeader(
                    reference: today.chapter.reference,
                    progressLabel: today.assignment.progressLabel,
                    progress: session.readFraction,
                    streak: model.displayedStreak,
                    streakStatus: model.streakStatus,
                    foreground: palette.foreground,
                    onChangeBook: { showBookPicker = true }
                )
                if let banner = model.banner {
                    EncouragementBanner(banner: banner, palette: palette) {
                        withAnimation(.spring(duration: 0.4)) { model.banner = nil }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if session.focusedPage != nil {
                    HStack {
                        Spacer()
                        VerseGroupingPicker(selection: session.versesPerCard, foreground: palette.foreground) { count in
                            withAnimation(.spring(duration: 0.35)) {
                                model.updatePreferences { $0.versesPerCard = count }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: session.focusedPage != nil)
            .animation(.spring(duration: 0.4), value: model.banner)
        }
        // Cards are sized to the screen; the checkpoint note keyboard must not resize them.
        .ignoresSafeArea(.keyboard)
        .onChange(of: session.focusedItemID) {
            model.audio.stopSpeaking()
        }
        .onDisappear { model.audio.stopSpeaking() }
        .sheet(item: $sharePage) { page in
            ShareCardSheet(chapter: today.chapter, verses: page.verses, typeface: prefs.typeface, palette: palette)
        }
        .sheet(item: $reflectionMood) { mood in
            ReflectionView(chapter: today.chapter, session: session, draft: model.reflectionDraft, initialMood: mood, palette: palette)
        }
        .sheet(item: $editingEntry) { entry in
            ReflectionView(editing: entry, chapter: today.chapter, palette: palette)
        }
        .sheet(isPresented: $showBookPicker) {
            NavigationStack { ChangeBookScreen() }
        }
    }

    @ViewBuilder
    private func card(for item: FeedItem, today: TodayContext, palette: Palette, prefs: ReadingPreferences) -> some View {
        switch item {
        case .intro:
            ChapterIntroCard(chapter: today.chapter, palette: palette)
        case .themes:
            ChapterThemesCard(chapter: today.chapter, palette: palette)
        case .checkpoint(let checkpoint):
            CheckpointCard(
                chapter: today.chapter,
                checkpoint: checkpoint,
                markedVerses: today.session.markedVerses.filter { checkpoint.range.contains($0.number) },
                palette: palette,
                note: today.session.note(for: checkpoint),
                onNoteChange: { today.session.setNote($0, for: checkpoint) }
            )
        case .verses(let page):
            let reference = today.chapter.reference(for: page.verses)
            VerseCardView(
                chapter: today.chapter,
                verses: page.verses,
                typeface: prefs.typeface,
                palette: palette,
                isMarked: today.session.isMarked(page),
                isSpeaking: model.audio.isSpeaking(reference),
                onToggleMark: { today.session.toggleMark(page) },
                onShare: { sharePage = page },
                onListen: { model.audio.toggleSpeaking(page.verses, reference: reference) },
                onToggleTypeface: { model.updatePreferences { $0.typeface = $0.typeface == .serif ? .sans : .serif } }
            )
        case .reflection:
            ReflectionPromptCard(
                chapter: today.chapter,
                isCompleted: today.assignment.isCompletedToday,
                streak: model.displayedStreak,
                palette: palette,
                todaysEntry: model.todaysReflection,
                draft: model.reflectionDraft,
                upNext: upNextLabel(today.assignment),
                isBookFinished: today.assignment.isBookFinished,
                onMoodSelected: { reflectionMood = $0 },
                onEdit: { editingEntry = $0 },
                onChooseBook: { showBookPicker = true }
            )
        }
    }

    private func upNextLabel(_ assignment: DailyAssignment) -> String? {
        guard let next = assignment.nextChapterID.flatMap(ChapterID.parse),
              let book = model.book(id: next.bookID) else { return nil }
        return "\(book.name) \(next.number)"
    }
}

private struct FeedHeader: View {
    let reference: String
    let progressLabel: String
    let progress: Double
    let streak: Int
    let streakStatus: StreakStatus
    let foreground: Color
    let onChangeBook: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: onChangeBook) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(reference)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .opacity(0.7)
                        }
                        Text(progressLabel)
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change book")
                Spacer()
                if case .repairable(let deadline) = streakStatus {
                    Label {
                        Text(deadline, style: .relative)
                    } icon: {
                        Image(systemName: "bandage.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.85), in: .capsule)
                    .accessibilityLabel("Streak repair available")
                }
                StreakBadge(count: streak, isAtRisk: streakStatus.isAtRisk)
            }
            ProgressRail(progress: progress, foreground: foreground)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// Full-screen vertical pager. Each card's position is derived from the focused index and the
/// current height, never from a stored scroll offset, so it can't come to rest between cards
/// after tab switches, sheets, the keyboard or a tap mid-swipe (all of which a paging
/// `ScrollView` could do). Only the focused card and its neighbours are built.
private struct CardPager<Card: View>: View {
    let items: [FeedItem]
    let focusedID: String?
    let onFocus: (String) -> Void
    @ViewBuilder let card: (FeedItem) -> Card

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private var currentIndex: Int {
        items.firstIndex { $0.id == focusedID } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let current = currentIndex
            let visible = items.indices.filter { abs($0 - current) <= 1 }
            ZStack(alignment: .top) {
                ForEach(visible, id: \.self) { index in
                    card(items[index])
                        .frame(width: geometry.size.width, height: height)
                        .offset(y: CGFloat(index - current) * height + dragOffset)
                        .id(items[index].id)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .top)
            .clipped()
            .contentShape(.rect)
            .gesture(drag(height: height, current: current))
            .accessibilityScrollAction { edge in
                switch edge {
                case .bottom: move(to: current + 1)
                case .top: move(to: current - 1)
                default: break
                }
            }
        }
    }

    private func drag(height: CGFloat, current: Int) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dy = value.translation.height
                guard isDragging || abs(dy) > abs(value.translation.width) else { return }
                isDragging = true
                let atEdge = (current == 0 && dy > 0) || (current == items.count - 1 && dy < 0)
                dragOffset = atEdge ? dy * 0.25 : dy
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                let dy = value.translation.height
                let projected = value.predictedEndTranslation.height
                var target = current
                if dy < -height * 0.2 || projected < -height * 0.5 {
                    target = current + 1
                } else if dy > height * 0.2 || projected > height * 0.5 {
                    target = current - 1
                }
                move(to: target)
            }
    }

    private func move(to index: Int) {
        let clamped = min(max(index, 0), items.count - 1)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            dragOffset = 0
            if items.indices.contains(clamped) { onFocus(items[clamped].id) }
        }
    }
}

private struct EncouragementBanner: View {
    let banner: AppModel.Banner
    let palette: Palette
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: banner.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.subheadline.weight(.bold))
                Text(banner.message)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(palette.foreground)
        .padding(14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .sensoryFeedback(.success, trigger: banner.id)
        .task(id: banner.id) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { onDismiss() }
        }
    }
}

private struct ProgressRail: View {
    let progress: Double
    let foreground: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(foreground.opacity(0.2))
                Capsule()
                    .fill(foreground.opacity(0.9))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 3)
        .animation(.spring(duration: 0.4), value: progress)
        .accessibilityLabel("Chapter progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

extension StreakStatus {
    var isAtRisk: Bool {
        if case .repairable = self { return true }
        return false
    }
}
