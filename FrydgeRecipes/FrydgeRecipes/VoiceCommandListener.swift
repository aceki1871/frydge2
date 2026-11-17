//
//  VoiceCommandListener.swift
//  FrydgeRecipes
//
//  Continuous on-device speech recognition for Cook Mode voice commands.
//  Publishes a new VoiceCommandEvent whenever a keyword is heard.
//  Each event has a unique ID so .onChange fires even for repeated commands.
//

import Speech
import AVFoundation

// MARK: - Public types

enum VoiceCommand: Equatable {
    case next
    case back
    case `repeat`
    case timer
    case check
}

struct VoiceCommandEvent: Equatable {
    let command: VoiceCommand
    let id: UUID

    init(_ command: VoiceCommand) {
        self.command = command
        self.id = UUID()
    }
}

// MARK: - Listener

final class VoiceCommandListener: ObservableObject {

    @Published private(set) var isListening: Bool = false
    @Published private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published private(set) var lastEvent: VoiceCommandEvent? = nil

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Debounce – ignore duplicate detections within this window
    private var lastCommandDate: Date = .distantPast
    private let commandCooldown: TimeInterval = 1.5

    // MARK: - Public

    @MainActor
    func requestAuthorization() async {
        // Speech recognition
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        // Microphone
        _ = await AVAudioApplication.requestRecordPermission()
        authorizationStatus = speechStatus
    }

    func start() {
        guard authorizationStatus == .authorized,
              recognizer?.isAvailable == true,
              !audioEngine.isRunning else { return }
        do {
            try beginSession()
        } catch {
            print("[VoiceCmd] Start failed: \(error)")
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        DispatchQueue.main.async { [weak self] in self?.isListening = false }
    }

    // MARK: - Private

    private func beginSession() throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep recognition fully on-device where the hardware supports it
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // Capture the request locally so the audio tap closure is concurrency-safe
        let capturedRequest = request
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        // installAudioTap replaces installTap (deprecated in iOS 27). It delivers a
        // Sendable read-only buffer that the speech request can't consume directly,
        // so each buffer is copied into a mutable PCM buffer before appending.
        try inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { buffer, _ in
            guard let pcmBuffer = Self.makePCMBuffer(copying: buffer) else { return }
            capturedRequest.append(pcmBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        DispatchQueue.main.async { [weak self] in self?.isListening = true }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString.lowercased() {
                self.processText(text)
            }
            // Restart when the current segment ends so listening is continuous
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async { [weak self] in
                    self?.stop()
                    self?.start()
                }
            }
        }
    }

    /// Copies a read-only tap buffer into an `AVAudioPCMBuffer`, the only buffer
    /// type `SFSpeechAudioBufferRecognitionRequest.append` accepts.
    private static func makePCMBuffer(copying source: AVReadOnlyAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(source.frameLength)
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount) else { return nil }
        copy.frameLength = frameCount
        source.withUnsafeAudioBufferList { sourceList in
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: sourceList))
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
                guard let from = sourceBuffer.mData, let to = destinationBuffer.mData else { continue }
                memcpy(to, from, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
            }
        }
        return copy
    }

    private func processText(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastCommandDate) > commandCooldown else { return }

        let cmd: VoiceCommand?
        if text.contains("next") {
            cmd = .next
        } else if text.contains("back") || text.contains("previous") || text.contains("go back") {
            cmd = .back
        } else if text.contains("repeat") || text.contains("again") || text.contains("say that again") {
            cmd = .repeat
        } else if text.contains("how long") || text.contains("time left") || text.contains("timer") {
            cmd = .timer
        } else if text.contains("check") || text.contains("how's this") || text.contains("how is this") || text.contains("looking") {
            cmd = .check
        } else {
            cmd = nil
        }

        guard let cmd else { return }
        lastCommandDate = now
        DispatchQueue.main.async { [weak self] in
            self?.lastEvent = VoiceCommandEvent(cmd)
        }
    }
}
