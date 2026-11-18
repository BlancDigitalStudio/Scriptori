import ScriptoriKit
import SwiftUI

/// A finished chapter's full text, to reread. Just the verses: no reflection, check-in or
/// streak, since those were handled when the chapter was read.
struct ChapterReaderView: View {
    @Environment(AppModel.self) private var model

    let chapterID: String

    @State private var chapter: BibleChapter?
    @State private var didFail = false

    private var typeface: Typeface { model.profile?.preferences.typeface ?? .serif }

    var body: some View {
        ZStack {
            let palette = chapter.map { Palette.named($0.palette) } ?? .dawn
            PaletteBackground(palette: palette)
            Group {
                if let chapter {
                    reader(chapter, palette: palette)
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
        .toolbarColorScheme(chapter.map { Palette.named($0.palette).isLight } == true ? .light : .dark, for: .navigationBar)
        .task(id: chapterID) {
            chapter = await model.chapter(id: chapterID)
            didFail = chapter == nil
        }
    }

    private func reader(_ chapter: BibleChapter, palette: Palette) -> some View {
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
