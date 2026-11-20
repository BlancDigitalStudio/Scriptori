import ScriptoriKit
import SwiftUI

/// A finished chapter's text, to reread. Just the verses: no reflection, check-in or streak,
/// since those were handled when the chapter was read. The reader picks 1, 2 or 3 verses per
/// card, swiped like the Today feed, or the whole chapter on one scrolling page.
struct ChapterReaderView: View {
    @Environment(AppModel.self) private var model

    let chapterID: String

    @State private var chapter: BibleChapter?
    @State private var didFail = false
    /// 0 shows every verse at once; 1–3 is verses per card.
    @AppStorage("scriptori.rereadVersesPerCard") private var versesPerCard = 0
    @State private var focusedID: String?

    private var typeface: Typeface { model.profile?.preferences.typeface ?? .serif }

    var body: some View {
        let palette = chapter.map { Palette.named($0.palette) } ?? .dawn
        ZStack {
            PaletteBackground(palette: palette)
            Group {
                if let chapter {
                    if versesPerCard == 0 {
                        allVerses(chapter, palette: palette)
                    } else {
                        cards(chapter, palette: palette)
                    }
                } else if didFail {
                    ContentUnavailableView("Couldn't open this chapter", systemImage: "book.closed")
                } else {
                    ProgressView().tint(palette.foreground)
                }
            }
            .foregroundStyle(palette.foreground)
        }
        .navigationTitle(chapter?.reference ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(palette.isLight ? .light : .dark, for: .navigationBar)
        .toolbar {
            if chapter != nil {
                ToolbarItem(placement: .topBarTrailing) { groupingMenu }
            }
        }
        .task(id: chapterID) {
            chapter = await model.chapter(id: chapterID)
            didFail = chapter == nil
        }
    }

    // MARK: Grouping

    private var groupingMenu: some View {
        Menu {
            Picker("Verses at a time", selection: groupingBinding) {
                ForEach(ReadingPreferences.versesPerCardRange, id: \.self) { count in
                    Text("\(count) verse\(count == 1 ? "" : "s")").tag(count)
                }
                Text("All verses").tag(0)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text(versesPerCard == 0 ? "All" : "\(versesPerCard)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .accessibilityLabel("Verses at a time: \(versesPerCard == 0 ? "all" : "\(versesPerCard)")")
    }

    /// Switching keeps the reader on the verse they were looking at when cards are involved.
    private var groupingBinding: Binding<Int> {
        Binding(
            get: { versesPerCard },
            set: { newValue in
                guard newValue != versesPerCard, let chapter else { return }
                let anchor = currentPage(in: chapter)?.firstVerse ?? 1
                withAnimation(.spring(duration: 0.35)) {
                    versesPerCard = newValue
                    if newValue > 0 {
                        let pages = pages(for: chapter, size: newValue)
                        let index = VersePaginator.pageIndex(containing: anchor, in: pages)
                        focusedID = pages.indices.contains(index) ? FeedItem.verses(pages[index]).id : nil
                    }
                }
            }
        )
    }

    private func pages(for chapter: BibleChapter, size: Int) -> [VersePage] {
        VersePaginator.pages(for: chapter.verses, versesPerCard: size)
    }

    private func currentPage(in chapter: BibleChapter) -> VersePage? {
        guard versesPerCard > 0 else { return nil }
        return pages(for: chapter, size: versesPerCard).first { FeedItem.verses($0).id == focusedID }
    }

    // MARK: Layouts

    private func cards(_ chapter: BibleChapter, palette: Palette) -> some View {
        let items = pages(for: chapter, size: versesPerCard).map(FeedItem.verses)
        return CardPager(
            items: items,
            focusedID: focusedID ?? items.first?.id,
            onFocus: { focusedID = $0 }
        ) { item in
            if case .verses(let page) = item {
                RereadCard(chapter: chapter, page: page, typeface: typeface, palette: palette)
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: focusedID)
    }

    private func allVerses(_ chapter: BibleChapter, palette: Palette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chapter.reference)
                        .font(Typography.display(34))
                    if let title = chapter.title {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryForeground)
                    }
                }
                .padding(.bottom, 8)

                ForEach(chapter.verses) { verse in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(verse.number)")
                            .font(.system(size: 12, weight: .semibold, design: typeface.design).monospacedDigit())
                            .foregroundStyle(palette.accent)
                            .frame(width: 24, alignment: .trailing)
                        Text(verse.text)
                            .font(Typography.verse(20, typeface))
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}

/// One card of verses for rereading: the Today card's text, without its mark/share/listen rail.
private struct RereadCard: View {
    let chapter: BibleChapter
    let page: VersePage
    let typeface: Typeface
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VerseText(
                verses: page.verses,
                typeface: typeface,
                size: Typography.verseSize(forCharacterCount: page.verses.reduce(0) { $0 + $1.text.count }),
                palette: palette
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(chapter.reference(for: page.verses))
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(palette.secondaryForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }
}
