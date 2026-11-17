//
//  SpeechCoach.swift
//  FrydgeRecipes
//
//  TTS wrapper for Cook Mode. Speaks step text aloud with a natural voice
//  at a slightly reduced rate so instructions are easy to follow.
//

import AVFoundation

final class SpeechCoach: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var isEnabled: Bool = true
    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = preferredVoice()
        // Slightly faster than 0.88 feels more conversational; still calm and clear
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.91
        // Slightly lower pitch sounds warmer and less robotic
        utterance.pitchMultiplier = 0.94
        utterance.volume = 0.95
        utterance.preUtteranceDelay = 0.06
        utterance.postUtteranceDelay = 0.18
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    // MARK: - Private

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-") }
        // rawValue 3 = .premium (neural TTS, iOS 16+) — sounds most natural
        // rawValue 2 = .enhanced — still noticeably better than default
        // rawValue 1 = .default  — system standard
        return all.first { $0.quality.rawValue >= 3 }
            ?? all.first { $0.quality == .enhanced }
            ?? all.first { $0.quality == .default }
            ?? AVSpeechSynthesisVoice(language: "en-AU")
    }
}
