import ScriptoriKit
import SwiftUI

/// Background palettes keyed by `BibleChapter.palette`.
struct Palette: Identifiable, Hashable {
    let id: String
    let colors: [Color]
    let accent: Color

    static let dawn = Palette(id: "dawn", colors: [Color(hex: 0x2B1E3F), Color(hex: 0x7A4A6E), Color(hex: 0xE59A7A)], accent: Color(hex: 0xFFD3A8))
    static let meadow = Palette(id: "meadow", colors: [Color(hex: 0x10261E), Color(hex: 0x2F5D46), Color(hex: 0x9CC59A)], accent: Color(hex: 0xD8F0C8))
    static let ocean = Palette(id: "ocean", colors: [Color(hex: 0x0B1A2F), Color(hex: 0x1E4C72), Color(hex: 0x6FB1C8)], accent: Color(hex: 0xBFE9F5))
    static let dusk = Palette(id: "dusk", colors: [Color(hex: 0x14122B), Color(hex: 0x433A7A), Color(hex: 0xB28DD6)], accent: Color(hex: 0xE6D4FF))
    static let ember = Palette(id: "ember", colors: [Color(hex: 0x2A140E), Color(hex: 0x7E3B22), Color(hex: 0xE8A25C)], accent: Color(hex: 0xFFE0B5))
    static let paper = Palette(id: "paper", colors: [Color(hex: 0xF7F1E6), Color(hex: 0xEFE4D2), Color(hex: 0xE3D3B8)], accent: Color(hex: 0x7A5230))

    static let all: [Palette] = [.dawn, .meadow, .ocean, .dusk, .ember, .paper]

    static func named(_ name: String) -> Palette {
        all.first { $0.id == name } ?? .dawn
    }

    var isLight: Bool { id == "paper" }
    var foreground: Color { isLight ? Color(hex: 0x2A2118) : .white }
    var secondaryForeground: Color { foreground.opacity(0.65) }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    /// Tint for the system-styled (light/dark) screens: Journal, Profile, settings lists.
    static let brandTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(Color(hex: 0xE59A7A)) : UIColor(Color(hex: 0x7A4A6E))
    })

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Typeface {
    var design: Font.Design { self == .serif ? .serif : .default }
    var label: String { self == .serif ? "Serif" : "Sans" }
}

enum Typography {
    static func verse(_ size: CGFloat, _ typeface: Typeface) -> Font {
        .system(size: size, weight: .regular, design: typeface.design)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    /// Scales verse text down as more (or longer) verses share one card.
    static func verseSize(forCharacterCount count: Int) -> CGFloat {
        switch count {
        case ..<90: 34
        case ..<200: 28
        case ..<380: 24
        case ..<600: 21
        default: 18
        }
    }
}

/// Slowly drifting gradient backdrop that makes the feed feel alive without distracting.
struct PaletteBackground: View {
    let palette: Palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                palette.gradient
                Circle()
                    .fill(palette.colors[2].opacity(0.45))
                    .frame(width: 420)
                    .blur(radius: 120)
                    .offset(x: CGFloat(sin(t / 7)) * 120, y: CGFloat(cos(t / 9)) * 220)
                Circle()
                    .fill(palette.accent.opacity(0.18))
                    .frame(width: 320)
                    .blur(radius: 110)
                    .offset(x: CGFloat(cos(t / 11)) * -140, y: CGFloat(sin(t / 8)) * 260)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: palette)
    }
}
