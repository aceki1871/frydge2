//
//  LiveActivityPushManager.swift
//  FrydgeRecipes
//
//  Push-to-start for the store-arrival Live Activity.
//
//  WHY THIS EXISTS
//  ---------------
//  ActivityKit refuses to start a Live Activity while the app is backgrounded
//  ("Target is not foreground"). Geofence callbacks always arrive in the
//  background, so `Activity.request` can never work from `didEnterRegion`.
//
//  Push-to-start (iOS 17.2+) is the only way around it: the system will create a
//  Live Activity in response to an APNs push, with no foreground requirement.
//
//  THE FLOW
//  --------
//    1. App launch  → subscribe to `pushToStartTokenUpdates`, cache the token.
//    2. Geofence    → POST { token, storeName, items } to the Cloudflare Worker.
//    3. Worker      → signs an ES256 JWT and relays to APNs.
//    4. APNs        → iOS creates the Live Activity and wakes the app.
//
//  The token travels WITH the request, so the Worker is a stateless relay and
//  never stores device tokens.
//
//  DEGRADATION
//  -----------
//  Step 2 needs network in a supermarket carpark and only ~10–30s of background
//  time. When it fails, `ActivityManager`'s existing deferred-start path still
//  fires when the user next opens the app, so nothing is lost — it just isn't
//  automatic. Both paths are deliberately kept.
//

import Foundation
import ActivityKit
import UIKit
import os

@MainActor
final class LiveActivityPushManager {

    static let shared = LiveActivityPushManager()

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "LiveActivityPush")

    /// Worker route. Bound in wrangler-liveactivity.toml.
    private let endpoint = URL(string: "https://frydge2.com/live-activity/start")!

    /// Shared secret so the relay isn't fully open. Not a security boundary —
    /// push-to-start tokens are per-device and only usable by this app — but it
    /// keeps casual abuse off the Worker.
    private let relayKey = "frydge2liveactivity"

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let pushToStartTokenKey = "liveActivityPushToStartToken"

    private var tokenObserver: Task<Void, Never>?
    private var activityObserver: Task<Void, Never>?

    private init() {}

    // MARK: - Token lifecycle

    /// Cached push-to-start token, shared via the App Group so a background
    /// launch can read it without waiting for the async sequence to yield.
    private(set) var pushToStartToken: String? {
        get { UserDefaults(suiteName: appGroupName)?.string(forKey: pushToStartTokenKey) }
        set {
            let ud = UserDefaults(suiteName: appGroupName)
            if let newValue { ud?.set(newValue, forKey: pushToStartTokenKey) }
            else { ud?.removeObject(forKey: pushToStartTokenKey) }
        }
    }

    /// Call once at launch. Idempotent.
    func start() {
        guard tokenObserver == nil else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.warning("Live Activities disabled — not subscribing to push-to-start tokens.")
            return
        }

        // iOS reissues this token; never assume it is stable.
        tokenObserver = Task { [weak self] in
            for await tokenData in Activity<ShoppingListActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.pushToStartToken = hex

                #if DEBUG
                // Full token, unredacted, so it can be pasted into a curl to test
                // the relay without walking to a shop. `os.Logger` redacts
                // interpolated strings by default — hence the explicit
                // `privacy: .public`. DEBUG only; never log this in release.
                Self.log.notice("Push-to-start token (full): \(hex, privacy: .public)")
                print("[PUSH-TO-START TOKEN] \(hex)")
                #else
                Self.log.notice("Push-to-start token updated (\(hex.prefix(8))…)")
                #endif
            }
        }

        // Update tokens for activities that were started by push, so the list can
        // be refreshed remotely later.
        activityObserver = Task {
            for await activity in Activity<ShoppingListActivityAttributes>.activityUpdates {
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                        Self.log.notice("Activity update token for \(activity.id): \(hex.prefix(12))…")
                    }
                }
            }
        }
    }

    // MARK: - Arrival

    /// Asks the Worker to start a Live Activity for this store.
    ///
    /// Safe to call from a geofence callback: it takes a background task
    /// assertion so iOS doesn't suspend the app mid-request, and it never throws.
    func requestStart(storeName: String, items: [String]) {
        guard let token = pushToStartToken, !token.isEmpty else {
            Self.log.warning("No push-to-start token yet — cannot push for \(storeName). Falling back to deferred start.")
            return
        }

        // Geofence wakeups give very little time. Without this assertion the
        // request is routinely killed mid-flight.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityPushToStart") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        Task {
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(relayKey, forHTTPHeaderField: "X-Frydge-Key")
            request.timeoutInterval = 12

            let body: [String: Any] = [
                "pushToStartToken": token,
                "storeName": storeName,
                "items": items,
                // Mirrors aps-environment. Flip to "production" when the
                // entitlement does, or the push lands on the wrong APNs host and
                // fails with BadDeviceToken.
                "environment": Self.apnsEnvironment
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            request.httpBody = data

            do {
                let (respData, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: respData, encoding: .utf8) ?? ""
                if (200..<300).contains(code) {
                    Self.log.notice("Push-to-start accepted for \(storeName)")
                } else {
                    Self.log.error("Push-to-start relay failed (\(code)): \(text)")
                }
            } catch {
                Self.log.error("Push-to-start relay error: \(String(describing: error))")
            }
        }
    }

    /// Must track the `aps-environment` entitlement value.
    ///
    /// Debug builds are signed with the development APNs environment and MUST use
    /// the sandbox host; release builds use production. Sending to the wrong host
    /// returns `BadDeviceToken`, which is the single most common reason
    /// push-to-start "works on my device but not in TestFlight".
    static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}
