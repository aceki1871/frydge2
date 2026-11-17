//
//  NetworkMonitor.swift
//  FrydgeRecipes
//
//  Created by Josh on 01/12/2024.
//
//  Rewritten to fix P2-1 from CODE_REVIEW_2026-08.md. The previous version had
//  three problems:
//
//    1. DATA RACE. `NWPathMonitor.currentPath` was mutated on a private dispatch
//       queue and read directly from the main actor with no synchronisation.
//       Under Swift 6 strict concurrency this is a hard error; before that it was
//       a latent race on a value that gated every CloudKit write in the app.
//
//    2. COLD START RETURNED FALSE. `start(queue:)` is asynchronous — `currentPath`
//       is not `.satisfied` until the first path update lands. Because the class
//       was lazily created, the first `isNetworkAvailable()` after launch
//       routinely answered "offline" and the first sync of every session was
//       silently skipped with no retry.
//
//    3. CROSS-SINGLETON INIT OFF-MAIN. The path handler called
//       `Networking.shared.syncOfflineRecipes()` directly from the monitor's
//       background queue, forcing another singleton to initialise off the main
//       thread. That dependency is now injected instead.
//
//  Note: the fridge and shopping list no longer consult this at all — they are
//  backed by NSPersistentCloudKitContainer, which manages its own connectivity,
//  queueing and retry. This remains for the recipe and marketplace paths that
//  still make raw URL requests.
//

import Foundation
import Network
import os

final class NetworkMonitor: @unchecked Sendable {

    static let shared = NetworkMonitor()

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "NetworkMonitor")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.Clark-Online.Recipes.NetworkMonitor")

    /// Guards every mutable property below. The type is `@unchecked Sendable`
    /// because this lock provides the safety the compiler cannot verify.
    private let lock = NSLock()
    private var latestStatus: NWPath.Status?
    private var onBecameReachable: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let wasReachable = (self.snapshotStatus() == .satisfied)

            self.lock.lock()
            self.latestStatus = path.status
            let callback = self.onBecameReachable
            self.lock.unlock()

            if path.status == .satisfied {
                if !wasReachable {
                    Self.log.notice("Network became reachable")
                    // Hop to main — the handler touches UI-facing singletons.
                    DispatchQueue.main.async { callback?() }
                }
            } else {
                Self.log.notice("Network unreachable")
            }
        }
        monitor.start(queue: queue)
    }

    private func snapshotStatus() -> NWPath.Status? {
        lock.lock()
        defer { lock.unlock() }
        return latestStatus
    }

    /// Whether the network is currently reachable.
    ///
    /// Returns `true` when the monitor has not reported yet. Optimism is
    /// deliberately the default: a wrong "offline" answer at launch made callers
    /// skip work and never retry, whereas a wrong "online" answer merely means the
    /// request fails and normal error handling runs.
    func isNetworkAvailable() -> Bool {
        guard let status = snapshotStatus() else { return true }
        return status == .satisfied
    }

    /// True only once the monitor has actually reported a path.
    var hasDeterminedStatus: Bool {
        snapshotStatus() != nil
    }

    /// Registers a callback for connectivity being restored. Call once, early —
    /// e.g. from the app delegate. Replaces the hardcoded reach into
    /// `Networking.shared` from a background queue.
    func setReachabilityHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onBecameReachable = handler
        lock.unlock()
    }
}
