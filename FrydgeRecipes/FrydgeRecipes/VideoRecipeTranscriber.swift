//
//  VideoRecipeTranscriber.swift
//  FrydgeRecipes
//
//  Transcribes speech from a local video file using SFSpeechRecognizer,
//  then feeds the text to RecipeImportOCRParser to extract a recipe draft.
//

import Foundation
import Speech

final class VideoRecipeTranscriber: ObservableObject {

    enum State: Equatable {
        case idle
        case transcribing
        case done(transcript: String)
        case failed(String)
    }

    @Published var state: State = .idle

    @MainActor
    func transcribe(videoURL: URL) {
        state = .transcribing
        Task {
            do {
                let transcript = try await Self.performTranscription(videoURL: videoURL)
                state = .done(transcript: transcript)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    func reset() {
        state = .idle
    }

    // MARK: - Internal

    private static func performTranscription(videoURL: URL) async throws -> String {
        let authStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }

        guard authStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable else {
            // Retry with en-US as fallback
            guard let fallback = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  fallback.isAvailable else {
                throw TranscriptionError.recognizerUnavailable
            }
            return try await recognize(with: fallback, videoURL: videoURL)
        }

        return try await recognize(with: recognizer, videoURL: videoURL)
    }

    private static func recognize(with recognizer: SFSpeechRecognizer, videoURL: URL) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition permission is required. Please enable it in Settings → Privacy & Security → Speech Recognition."
            case .recognizerUnavailable:
                return "Speech recognition is not available right now. Please check your internet connection and try again."
            }
        }
    }
}

// MARK: - App Group Video Queue

enum VideoImportQueue {
    static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    static let metaFilename = "pending_recipe_video_meta.json"

    struct Meta: Codable {
        var videoPath: String
        var createdAt: String
    }

    static func pendingVideoURL() -> URL? {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let metaURL = folder.appendingPathComponent(metaFilename)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        let videoURL = folder.appendingPathComponent(meta.videoPath)
        return FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
    }

    static func clear() {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let metaURL = folder.appendingPathComponent(metaFilename)
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(Meta.self, from: data) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(meta.videoPath))
        }
        try? FileManager.default.removeItem(at: metaURL)
    }
}
