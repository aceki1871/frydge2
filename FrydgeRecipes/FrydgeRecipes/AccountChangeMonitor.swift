import CloudKit
import Foundation
import UIKit
import WidgetKit

/// Detects an iCloud account change while the app stays installed and resets
/// per-user state so the previous account's inventory, shopping list, plan,
/// receipts and marketplace orders are neither shown to nor written on behalf
/// of the next account.
///
/// Background: `FrydgeManager` and `ShoppingListManager` resolve `appleUserID`
/// once and cache it in UserDefaults. Their resolvers return early whenever a
/// non-install id is already stored, so a device that switched iCloud accounts
/// kept scoping files, backups and marketplace requests to the old identity.
///
/// Scope note: the Core Data store is one file shared by every account on the
/// device. `NSPersistentCloudKitContainer` is documented to purge and
/// re-import mirrored data when the account changes; that behaviour still has
/// to be verified on two physical test accounts before the release gate in
/// the repair plan (workstream D1) is considered met.
@MainActor
final class AccountChangeMonitor {
    static let shared = AccountChangeMonitor()

    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private var observers: [NSObjectProtocol] = []
    private var checkInFlight = false
    private var started = false

    private init() {}

    /// Registers for account-change and foreground notifications. Safe to call
    /// more than once; only the first call installs observers.
    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.revalidate(reason: "CKAccountChanged") }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.revalidate(reason: "foreground") }
        })

        Task { @MainActor in await revalidate(reason: "launch") }
    }

    /// Compares the stored `appleUserID` with the account CloudKit reports now.
    /// On a mismatch the stored id is replaced and every per-user cache is
    /// cleared and reloaded under the new identity.
    func revalidate(reason: String) async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        let stored = UserDefaults.standard.string(forKey: "appleUserID") ?? ""

        let resolved: String
        do {
            resolved = try await container.userRecordID().recordName
        } catch {
            // No account, or offline. Do not wipe state on a transient failure;
            // the managers keep running under the stored id until we can tell.
            print("[AccountChangeMonitor] could not resolve account (\(reason)): \(error.localizedDescription)")
            return
        }

        // The very first resolution (install-scoped → real id) is handled by
        // the managers' own resolvers, including their one-time migration.
        guard !stored.isEmpty, !stored.hasPrefix("install_"), stored != "local" else { return }
        guard stored != resolved else { return }

        print("[AccountChangeMonitor] iCloud account changed (\(reason)); resetting per-user state")

        UserDefaults.standard.set(resolved, forKey: "appleUserID")
        UserDefaults(suiteName: appGroupName)?.set(resolved, forKey: "appleUserID")

        FrydgeManager.shared.handleAccountChange()
        ShoppingListManager.current?.handleAccountChange()
        WeekPlanStore.shared.handleAccountChange()
        MarketplaceOrderService.shared.clearForAccountChange()
        ReceiptStore.shared.clearForAccountChange()

        // Widget and Watch snapshots were written under the previous id.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
