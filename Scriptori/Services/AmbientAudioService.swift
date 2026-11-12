import AVFoundation
import Observation
import ScriptoriKit

/// Meditative audio layer: procedurally generated soundscapes (soft rain, waves, wind; no
/// assets needed) and on-demand verse voiceover.
@Observable
@MainActor
final class AmbientAudioService {
    private(set) var sound: AmbientSound = .off
    /// Reference of the card being read aloud, e.g. "Genesis 1:1–3", while speech is playing.
    private(set) var speakingReference: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var noiseNode: AVAudioSourceNode?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let speechDelegate = SpeechDelegate()

    init() {
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in self?.speakingReference = nil }
    }

    func setSound(_ newValue: AmbientSound) {
        guard newValue != sound else { return }
        stopSoundscape()
        sound = newValue
        guard newValue != .off else {
            stopSpeaking()
            return
        }
        activateSession()
        startSoundscape(newValue)
    }

    func isSpeaking(_ reference: String) -> Bool {
        speakingReference == reference
    }

    /// Reads a card aloud, or stops if that card is already being read.
    func toggleSpeaking(_ verses: [BibleVerse], reference: String) {
        if isSpeaking(reference) {
            stopSpeaking()
        } else {
            speak(verses, reference: reference)
        }
    }

    func speak(_ verses: [BibleVerse], reference: String) {
        synthesizer.stopSpeaking(at: .immediate)
        activateSession()
        let utterance = AVSpeechUtterance(string: verses.map(\.text).joined(separator: " "))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 0.95
        utterance.postUtteranceDelay = 0.3
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speakingReference = reference
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingReference = nil
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func startSoundscape(_ sound: AmbientSound) {
        let format = engine.outputNode.inputFormat(forBus: 0)
        guard let node = Self.makeNode(for: sound, sampleRate: format.sampleRate) else { return }
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
        engine.mainMixerNode.outputVolume = 0
        noiseNode = node
        try? engine.start()
        fade(to: 0.35)
    }

    private func fade(to volume: Float) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            for step in 1...20 {
                guard !Task.isCancelled else { return }
                engine.mainMixerNode.outputVolume = volume * Float(step) / 20
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopSoundscape() {
        fadeTask?.cancel()
        fadeTask = nil
        guard let noiseNode else { return }
        engine.mainMixerNode.outputVolume = 0
        engine.stop()
        engine.detach(noiseNode)
        self.noiseNode = nil
    }

    // MARK: Soundscapes

    private final class NoiseState: @unchecked Sendable {
        var low: Float = 0
        var lowFast: Float = 0
        var phase: Double = 0
        var phase2: Double = 0
    }

    private nonisolated static func makeNode(for sound: AmbientSound, sampleRate: Double) -> AVAudioSourceNode? {
        let render: (NoiseState, Float) -> Float
        let step = 2 * Double.pi / sampleRate
        switch sound {
        case .off:
            return nil
        case .rain:
            // Brown-ish noise with slow amplitude drift, which reads as gentle rainfall.
            render = { state, white in
                state.low = (state.low + 0.02 * white) / 1.02
                state.phase += step * 0.07
                let swell = Float(0.75 + 0.25 * sin(state.phase))
                return (state.low * 3.2 + white * 0.035) * swell
            }
        case .waves:
            // Deep rumble that swells and recedes every ~9 s, with a hiss of foam at each crest.
            render = { state, white in
                state.low += 0.012 * (white - state.low)
                state.lowFast += 0.12 * (white - state.lowFast)
                state.phase += step / 9
                state.phase2 += step / 23
                let cycle = Float(0.5 - 0.5 * cos(state.phase))
                let variation = Float(0.8 + 0.2 * sin(state.phase2))
                let crest: Float = pow(cycle, 2.2) * variation
                let rumble: Float = state.low * 4.5 * (0.2 + 0.8 * crest)
                let foam: Float = state.lowFast * 0.5 * crest * crest
                return rumble + foam
            }
        case .wind:
            // Filtered noise whose brightness and loudness wander in slow, overlapping gusts.
            render = { state, white in
                state.phase += step / 7
                state.phase2 += step / 2.9
                let swell = Float(0.5 + 0.5 * sin(state.phase))
                let flutter = Float(0.65 + 0.35 * sin(state.phase2))
                let gust: Float = swell * flutter
                let cutoff: Float = 0.004 + 0.03 * gust
                state.low += cutoff * (white - state.low)
                let loudness: Float = 0.09 * (0.35 + 0.65 * gust)
                return state.low / cutoff.squareRoot() * loudness
            }
        }

        let state = NoiseState()
        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = render(state, Float.random(in: -1...1))
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    @MainActor var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}
