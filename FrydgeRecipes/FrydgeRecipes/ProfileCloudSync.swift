//
//  ProfileCloudSync.swift
//  FrydgeRecipes
//
//  Mirrors the editable profile fields (name, email, phone, etc.) between this
//  device's UserDefaults — which the @AppStorage bindings in ProfileView read —
//  and iCloud's key-value store, so the profile follows the user across devices.
//  Requires the `com.apple.developer.ubiquity-kvstore-identifier` entitlement.
//

import Foundation

final class ProfileCloudSync {

    static let shared = ProfileCloudSync()

    private let kvs = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard

    /// The @AppStorage keys mirrored across devices.
    private let keys = [
        "frydge.authorName",
        "frydge.profileDietary",
        // Specific can't / won't eat rules (JSON string, see DietaryRestrictionStore).
        DietaryRestrictionStore.defaultsKey,
        // Seller's Stripe Connect account id, so payouts work on every device.
        "frydge.stripe.connectAccountId"
    ]

    /// Guards against the write-back loop when we copy cloud → local.
    private var isApplyingFromCloud = false

    private init() {}

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudChanged(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        kvs.synchronize()
        pullFromCloud()   // cloud wins on launch when it has a value
        pushToCloud()     // seed the cloud from any values set before first sync
    }

    // MARK: - Cloud → local

    @objc private func cloudChanged(_ note: Notification) {
        pullFromCloud()
    }

    private func pullFromCloud() {
        isApplyingFromCloud = true
        defer { isApplyingFromCloud = false }
        for key in keys {
            // Only a *non-empty* cloud value is authoritative. An empty string must
            // never clobber a value the user has set on this device — that was the
            // bug that made the profile name disappear after relaunch/sync.
            guard let value = kvs.string(forKey: key), !value.isEmpty else { continue }
            if defaults.string(forKey: key) != value {
                defaults.set(value, forKey: key)
            }
        }
    }

    // MARK: - Local → cloud

    @objc private func defaultsChanged() {
        guard !isApplyingFromCloud else { return }
        pushToCloud()
    }

    private func pushToCloud() {
        var changed = false
        for key in keys {
            let local = defaults.string(forKey: key) ?? ""
            // Never seed empty values into the cloud: an empty seed would sync down
            // to other devices (and back on relaunch) and wipe good local values.
            guard !local.isEmpty else { continue }
            if kvs.string(forKey: key) != local {
                kvs.set(local, forKey: key)
                changed = true
            }
        }
        if changed { kvs.synchronize() }
    }
}
