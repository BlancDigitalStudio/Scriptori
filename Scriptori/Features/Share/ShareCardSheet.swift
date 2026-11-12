import ScriptoriKit
import SwiftUI
import UIKit

/// Branded 9:16 "Scriptori Card" for Instagram Stories, Messages, etc.
struct ShareCardView: View {
    let chapter: BibleChapter
    let verses: [BibleVerse]
    let typeface: Typeface
    let palette: Palette

    var body: some View {
        ZStack {
            palette.gradient
            Circle()
                .fill(palette.colors[2].opacity(0.5))
                .frame(width: 900)
                .blur(radius: 200)
                .offset(x: 300, y: -500)

            VStack(alignment: .leading, spacing: 48) {
                Spacer()
                Image(systemName: "quote.opening")
                    .font(.system(size: 72))
                    .foregroundStyle(palette.accent)
                VerseText(
                    verses: verses,
                    typeface: typeface,
                    size: Typography.verseSize(forCharacterCount: verses.reduce(0) { $0 + $1.text.count }) * 2.4,
                    palette: palette
                )
                Text("\(chapter.reference(for: verses)) · \(chapter.translation)")
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(3)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.secondaryForeground)
                Spacer()
                HStack(spacing: 14) {
                    Image(systemName: "leaf.fill")
                    Text("Scriptori").font(.system(size: 40, weight: .semibold, design: .serif))
                    Spacer()
                    Text("bloomscroll daily").font(.system(size: 28))
                }
                .foregroundStyle(palette.foreground.opacity(0.85))
            }
            .padding(90)
        }
        .frame(width: 1080, height: 1920)
    }
}

struct ShareCardSheet: View {
    let chapter: BibleChapter
    let verses: [BibleVerse]
    let typeface: Typeface
    @State var palette: Palette

    @State private var rendered: UIImage?

    /// Set to your Meta App ID to enable direct "Share to Instagram Stories".
    private let facebookAppID = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ShareCardView(chapter: chapter, verses: verses, typeface: typeface, palette: palette)
                    .scaleEffect(0.28)
                    .frame(width: 1080 * 0.28, height: 1920 * 0.28)
                    .clipShape(.rect(cornerRadius: 20))
                    .shadow(radius: 20)

                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Palette.all) { option in
                            Circle()
                                .fill(option.gradient)
                                .frame(width: 40, height: 40)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: option == palette ? 3 : 0))
                                .onTapGesture { palette = option }
                                .accessibilityLabel(option.id.capitalized)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)

                if let rendered {
                    ShareLink(
                        item: Image(uiImage: rendered),
                        preview: SharePreview(chapter.reference(for: verses), image: Image(uiImage: rendered))
                    ) {
                        Label("Share card", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .primary, foreground: Color(.systemBackground)))
                    .padding(.horizontal)

                    if !facebookAppID.isEmpty, let url = URL(string: "instagram-stories://share?source_application=\(facebookAppID)"), UIApplication.shared.canOpenURL(url) {
                        Button("Share to Instagram Stories") { shareToInstagram(rendered, url: url) }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle("Scriptori Card")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .task(id: palette) { render() }
    }

    private func render() {
        let renderer = ImageRenderer(content: ShareCardView(chapter: chapter, verses: verses, typeface: typeface, palette: palette))
        renderer.scale = 1
        rendered = renderer.uiImage
    }

    private func shareToInstagram(_ image: UIImage, url: URL) {
        guard let data = image.pngData() else { return }
        UIPasteboard.general.setItems(
            [["com.instagram.sharedSticker.backgroundImage": data]],
            options: [.expirationDate: Date.now.addingTimeInterval(300)]
        )
        UIApplication.shared.open(url)
    }
}
