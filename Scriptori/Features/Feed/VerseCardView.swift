import ScriptoriKit
import SwiftUI

/// One swipe card showing 1–3 verses with inline superscript verse numbers.
/// Double-tap (or the bookmark) marks the card's verses for the end-of-chapter reflection.
struct VerseCardView: View {
    let chapter: BibleChapter
    let verses: [BibleVerse]
    let typeface: Typeface
    let palette: Palette
    var isMarked = false
    var isSpeaking = false
    var onToggleMark: () -> Void = {}
    var onShare: () -> Void = {}
    var onListen: () -> Void = {}
    var onToggleTypeface: () -> Void = {}

    private var fontSize: CGFloat {
        Typography.verseSize(forCharacterCount: verses.reduce(0) { $0 + $1.text.count })
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 20) {
                VerseText(verses: verses, typeface: typeface, size: fontSize, palette: palette)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 44)
                    .layoutPriority(1)
                HStack(spacing: 8) {
                    Text(chapter.reference(for: verses))
                    if isMarked {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(palette.accent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(palette.secondaryForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            // Keeps text clear of the feed header above and the grouping picker / tab bar below.
            .padding(.top, 150)
            .padding(.bottom, 170)
            .contentShape(.rect)
            .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { onToggleMark() } }

            CardActionRail(foreground: palette.foreground, accent: palette.accent, typeface: typeface, isMarked: isMarked, isSpeaking: isSpeaking, onToggleMark: onToggleMark, onShare: onShare, onListen: onListen, onToggleTypeface: onToggleTypeface)
                .padding(.trailing, 14)
                .padding(.bottom, 150)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isMarked)
        .accessibilityElement(children: .contain)
    }
}

/// Verse text that shrinks to fit when 3 long verses share a small screen.
struct VerseText: View {
    let verses: [BibleVerse]
    let typeface: Typeface
    let size: CGFloat
    let palette: Palette

    var body: some View {
        Text(attributed)
            .font(Typography.verse(size, typeface))
            .lineSpacing(size * 0.32)
            .minimumScaleFactor(0.6)
            .foregroundStyle(palette.foreground)
            .contentTransition(.opacity)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, verse) in verses.enumerated() {
            if verses.count > 1 || verse.number > 1 {
                var number = AttributedString("\(verse.number)\u{2009}")
                number.font = .system(size: size * 0.45, weight: .semibold, design: typeface.design)
                number.baselineOffset = size * 0.38
                number.foregroundColor = palette.accent
                result += number
            }
            result += AttributedString(verse.text)
            if index < verses.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

private struct CardActionRail: View {
    let foreground: Color
    let accent: Color
    let typeface: Typeface
    let isMarked: Bool
    let isSpeaking: Bool
    let onToggleMark: () -> Void
    let onShare: () -> Void
    let onListen: () -> Void
    let onToggleTypeface: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Button {
                withAnimation(.spring(duration: 0.3)) { onToggleMark() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: isMarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isMarked ? accent : foreground)
                        .symbolEffect(.bounce, value: isMarked)
                    Text(isMarked ? "Marked" : "Mark").font(.caption2)
                }
            }
            .accessibilityLabel(isMarked ? "Unmark these verses" : "Mark these verses for your reflection")
            railButton("square.and.arrow.up", label: "Share", action: onShare)
            Button(action: onListen) {
                VStack(spacing: 4) {
                    Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSpeaking ? accent : foreground)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: isSpeaking)
                    Text(isSpeaking ? "Stop" : "Listen").font(.caption2)
                }
            }
            .accessibilityLabel(isSpeaking ? "Stop reading aloud" : "Listen")
            Button(action: onToggleTypeface) {
                VStack(spacing: 4) {
                    Text("Aa")
                        .font(.system(size: 20, weight: .semibold, design: typeface == .serif ? .default : .serif))
                    Text(typeface == .serif ? "Sans" : "Serif").font(.caption2)
                }
            }
            .accessibilityLabel("Switch to \(typeface == .serif ? "sans-serif" : "serif") font")
        }
        .foregroundStyle(foreground)
        .buttonStyle(.plain)
    }

    private func railButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                Text(label).font(.caption2)
            }
        }
        .accessibilityLabel(label)
    }
}

/// Floating 1–3 "verses per card" control.
struct VerseGroupingPicker: View {
    let selection: Int
    let foreground: Color
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.caption)
                .padding(.horizontal, 6)
                .opacity(0.7)
            ForEach(ReadingPreferences.versesPerCardRange, id: \.self) { count in
                Button { onSelect(count) } label: {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background {
                            if selection == count {
                                Circle().fill(foreground).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .foregroundStyle(selection == count ? Color.black : foreground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) verse\(count == 1 ? "" : "s") per card")
                .accessibilityAddTraits(selection == count ? .isSelected : [])
            }
        }
        .padding(4)
        .foregroundStyle(foreground)
        .background(.ultraThinMaterial, in: .capsule)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @Namespace private var namespace
}
