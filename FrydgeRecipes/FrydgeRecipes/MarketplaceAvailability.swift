//
//  MarketplaceAvailability.swift
//  FrydgeRecipes
//
//  Launch gate for the Local Marketplace. Lets the feature ship inside an
//  App Store build while staying invisible until it is switched on remotely.
//
//  RESOLUTION ORDER
//    1. Debug builds        → always on, so development is never blocked.
//    2. TestFlight builds   → always on (App Store sandbox environment), so
//                             testers see it before the public does.
//    3. App Store builds    → whatever GET /marketplace/config last returned,
//                             cached in UserDefaults. Defaults to OFF until the
//                             first successful fetch, and stays at the last
//                             known value when offline.
//
//  FLIPPING IT LIVE
//    Set MARKETPLACE_ENABLED = "true" in wrangler-marketplace.toml [vars] and
//    `wrangler deploy -c wrangler-marketplace.toml`. No app update needed.
//

import Foundation
import StoreKit

@MainActor
final class MarketplaceAvailability: ObservableObject {

    static let shared = MarketplaceAvailability()

    /// True when marketplace UI (tab, Profile section, tutorial page) should show.
    @Published private(set) var isEnabled: Bool

    /// Shelf switch. While true the marketplace stays hidden in every build
    /// (Debug, TestFlight and App Store alike), overriding the resolution
    /// order above. Flip to false to bring it back.
    static let isShelved = true

    private static let cacheKey = "marketplace.remoteEnabled"
    private var refreshTask: Task<Void, Never>?

    private init() {
        guard !Self.isShelved else {
            isEnabled = false
            return
        }
        #if DEBUG
        isEnabled = true
        #else
        isEnabled = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #endif
    }

    /// Re-evaluates the gate. Safe to call on every foreground; concurrent
    /// calls coalesce into one in-flight request.
    func refresh() {
        guard !Self.isShelved else { return }
        #if DEBUG
        // Debug is pinned on; nothing to fetch.
        return
        #else
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            guard let self else { return }

            if await Self.isTestFlightBuild() {
                self.isEnabled = true
                return
            }

            if let remote = await Self.fetchRemoteFlag() {
                UserDefaults.standard.set(remote, forKey: Self.cacheKey)
                self.isEnabled = remote
            }
        }
        #endif
    }

    // MARK: - Environment

    /// TestFlight installs are signed for the App Store sandbox; a real App
    /// Store install reports `.production`. Any failure counts as production
    /// so a verification hiccup never exposes the feature early.
    private static func isTestFlightBuild() async -> Bool {
        guard let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result else {
            return false
        }
        return transaction.environment == .sandbox
    }

    // MARK: - Remote flag

    /// Asks the marketplace worker whether the feature is live.
    /// Returns nil on any network or parsing failure so the cached value wins.
    private static func fetchRemoteFlag() async -> Bool? {
        guard let url = URL(string: "\(FrydgeBackend.host)/marketplace/config") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        FrydgeBackend.authorize(&request)

        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(ConfigResponse.self, from: result.0) else {
            return nil
        }
        return payload.marketplaceEnabled
    }

    private struct ConfigResponse: Decodable {
        let marketplaceEnabled: Bool
    }
}
