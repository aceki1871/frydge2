//
//  FrydgeBackend.swift
//  FrydgeRecipes
//
//  Single source of truth for the frydge-api worker host and the relay-key
//  credential that guards its /marketplace/* and /stripe/* routes.
//

import Foundation

/// Shared configuration for the Frydge Cloudflare worker.
///
/// The relay key is a shared secret that every request to `/marketplace/*` and
/// `/stripe/*` must carry as `X-Frydge-Key`, or the worker responds 401. It is
/// read from a gitignored `secrets.plist` bundled resource rather than being
/// hardcoded in source, so the credential never lands in version control. See
/// `.gitignore` ("secrets.plist") and the matching `FRYDGE_RELAY_KEY` on the worker.
enum FrydgeBackend {

    /// Base host for the worker. Route prefixes (`/marketplace`, `/stripe`) are
    /// appended by each caller, so the path after the host is unchanged.
    static let host = "https://frydge-api.davekitson-read.workers.dev"

    /// Shared relay secret, loaded once from `secrets.plist`.
    ///
    /// Empty when the file is missing (e.g. a fresh clone that hasn't supplied
    /// its own credential), which the worker rejects with 401 — the intended
    /// "bring your own key" behaviour.
    static let relayKey: String = FrydgeSecrets.value(for: "FrydgeRelayKey")

    /// Stamps the relay-key header onto a request bound for `/marketplace/*` or
    /// `/stripe/*`.
    static func authorize(_ request: inout URLRequest) {
        request.setValue(relayKey, forHTTPHeaderField: "X-Frydge-Key")
    }
}

/// Third-party credentials bundled via the gitignored `secrets.plist`.
///
/// Every accessor returns "" when the file or key is missing so callers can
/// degrade gracefully (skip the lookup) instead of shipping a key in source.
enum FrydgeSecrets {

    /// Parsed once; the plist is tiny and read-only.
    private static let plist: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    /// String value for `key`, trimmed; "" when absent.
    static func value(for key: String) -> String {
        (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Edamam Food Database API — https://developer.edamam.com
    static let edamamAppID  = value(for: "EdamamAppID")
    static let edamamAppKey = value(for: "EdamamAppKey")

    /// what3words — https://developer.what3words.com
    static let what3wordsAPIKey = value(for: "What3WordsAPIKey")
}
