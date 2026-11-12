import ScriptoriKit
import SwiftUI

struct CompletionCelebrationView: View {
    let result: CompletionResult
    let palette: Palette
    let onDone: () -> Void

    @State private var displayedCount = 0
    @State private var flameScale = 0.4
    @State private var showDetails = false

    private var streak: Int { result.streak.state.current }

    private var headline: String {
        if let milestone = result.streak.milestone { return "\(milestone)-day milestone!" }
        switch result.streak.event {
        case .repaired: return "Streak repaired"
        case .started: return "Your streak begins"
        case .restarted: return "A fresh start"
        default: return "Chapter complete"
        }
    }

    private var message: String {
        switch result.streak.event {
        case .repaired: "You used your Streak Repair to keep the chain alive. Welcome back."
        case .restarted(let previous): "Your previous best was \(previous) days. Every streak starts with day one."
        default: "You turned a scroll into a bloom. See you tomorrow for the next chapter."
        }
    }

    var body: some View {
        ZStack {
            if result.streak.milestone != nil {
                ConfettiView(colors: [palette.accent, .yellow, .orange, .white])
            }
            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [.orange.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 140))
                        .frame(width: 280, height: 280)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom))
                        .symbolEffect(.bounce, value: displayedCount)
                        .scaleEffect(flameScale)
                }
                Text("\(displayedCount)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: Double(displayedCount)))
                    .monospacedDigit()
                Text(streak == 1 ? "day streak" : "day streak · best \(result.streak.state.longest)")
                    .font(.headline)
                    .foregroundStyle(palette.secondaryForeground)

                if showDetails {
                    VStack(spacing: 10) {
                        Text(headline).font(Typography.display(28))
                        Text(message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(palette.secondaryForeground)
                        HStack(spacing: 24) {
                            stat("\(result.profile.totalChaptersRead)", "chapters")
                            stat("\(result.profile.reflectionCount)", "reflections")
                        }
                        .padding(.top, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(PrimaryButtonStyle(tint: palette.foreground, foreground: palette.isLight ? .white : .black))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .task { await animateIn() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(palette.secondaryForeground)
        }
    }

    private func animateIn() async {
        displayedCount = max(streak - 1, 0)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { flameScale = 1 }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.spring(duration: 0.5)) { displayedCount = streak }
        Haptics.selection()
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.spring(duration: 0.5)) { showDetails = true }
    }
}

/// Lightweight particle burst for streak milestones.
struct ConfettiView: View {
    let colors: [Color]
    @State private var start = Date.now

    private struct Particle {
        let x: Double, speed: Double, spin: Double, size: Double, color: Int, delay: Double
    }

    private let particles: [Particle] = (0..<90).map { _ in
        Particle(x: .random(in: 0...1), speed: .random(in: 180...420), spin: .random(in: -6...6), size: .random(in: 6...12), color: .random(in: 0..<4), delay: .random(in: 0...0.6))
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let elapsed = context.date.timeIntervalSince(start)
                for particle in particles {
                    let t = elapsed - particle.delay
                    guard t > 0 else { continue }
                    let y = -20 + particle.speed * t + 90 * t * t
                    guard y < size.height + 20 else { continue }
                    let x = particle.x * size.width + sin(t * 2 + particle.spin) * 24
                    var context = canvas
                    context.translateBy(x: x, y: y)
                    context.rotate(by: .radians(t * particle.spin))
                    let rect = CGRect(x: -particle.size / 2, y: -particle.size / 4, width: particle.size, height: particle.size / 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(colors[particle.color % colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
