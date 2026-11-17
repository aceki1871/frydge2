//
//  CookCoachService.swift
//  FrydgeRecipes
//
//  Single-frame cooking check-in. POSTs a JPEG snapshot + the current step
//  text to a backend endpoint that returns guidance text.
//
//  The app never embeds an AI provider key directly — the backend holds it.
//
//  TODO Phase 2: Replace one-shot image POST with ephemeral token minting so
//  the backend can return a Gemini Live / OpenAI Realtime WebSocket URL for
//  continuous back-and-forth voice guidance during the cook session.
//

import UIKit

enum CookCoachService {

    private static let endpoint = URL(string: "https://YOUR_BACKEND/cook-check")!

    /// Sends a single JPEG frame and the current step description to the backend
    /// and returns the coaching guidance string.
    static func checkStep(image: UIImage, stepText: String) async throws -> String {
        guard let jpeg = image.jpegData(compressionQuality: 0.72) else {
            throw URLError(.cannotEncodeRawData)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"

        let boundary = "FrydgeBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"step\"\r\n\r\n\(stepText)\r\n")
        body.appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let guidance = json["guidance"] as? String, !guidance.isEmpty {
            return guidance
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Looks good!"
    }
}

// MARK: - Helpers

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
