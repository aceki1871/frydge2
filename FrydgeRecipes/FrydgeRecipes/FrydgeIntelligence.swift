//
//  FrydgeIntelligence.swift
//  FrydgeRecipes
//
//  Shared gate and helper for every feature that calls Apple's on-device
//  Foundation Models. Every AI feature in the app must check `isAvailable`
//  (or call `generate`, which checks it) before using the model, so that a
//  single Settings toggle and a single capability check cover all of them.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum FrydgeIntelligence {

    /// User opt-out, surfaced in Profile. On by default so capable devices get
    /// the features immediately; this only ever turns things off.
    static let enabledKey = "frydge.appleIntelligenceEnabled"

    /// True when the device's on-device model is downloaded and ready, regardless
    /// of the user toggle. Used to decide whether to show the Settings toggle at all.
    static var isSupportedOnDevice: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// True when a feature may call the model: the device supports it AND the
    /// user hasn't turned it off. Every AI call site should gate on this.
    static var isAvailable: Bool {
        userEnabled && isSupportedOnDevice
    }

    private static var userEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Runs a single-shot generation against the on-device model. Returns nil on
    /// unavailability or any failure so callers can fall back to their existing
    /// heuristic without special-casing errors.
    @available(iOS 26.0, *)
    static func generate<T: Generable>(
        _ type: T.Type,
        instructions: String,
        prompt: String,
        logTag: StaticString
    ) async -> T? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: type)
            return response.content
        } catch {
            print("[\(logTag)] Generation error: \(error.localizedDescription)")
            return nil
        }
    }
}
