//
//  LeftoverManager.swift
//  FrydgeRecipes
//
//  Manages leftover items created after cooking a recipe.
//  Flow:
//   1. CookAlongView schedules a local notification 1 hour after cooking ends.
//   2. User taps "Store leftovers" → app opens LeftoverReminderSheet.
//   3. User sets portions + expiry days + destination (own / shared fridge).
//   4. LeftoverManager persists the item and, for shared destinations,
//      posts a CloudKit notification so fridge members are informed.
//

import Foundation
import UserNotifications
import CloudKit

// MARK: - Model

struct LeftoverItem: Identifiable, Codable {
    var id: UUID = UUID()
    var recipeName: String
    var cookedDate: Date
    var expiryDate: Date
    var portionsRemaining: Int
    var destination: LeftoverDestination

    enum LeftoverDestination: String, Codable, CaseIterable {
        case ownFridge   = "own"
        case sharedFridge = "shared"
        case freezer     = "freezer"

        var label: String {
            switch self {
            case .ownFridge:    return "My Fridge"
            case .sharedFridge: return "Shared Fridge"
            case .freezer:      return "Freezer"
            }
        }

        var icon: String {
            switch self {
            case .ownFridge:    return "refrigerator"
            case .sharedFridge: return "person.2.fill"
            case .freezer:      return "snowflake"
            }
        }
    }

    var daysUntilExpiry: Int {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day ?? 0
        return max(0, days)
    }

    var isExpired: Bool { Date() > expiryDate }

    var expiryLabel: String {
        let d = daysUntilExpiry
        if isExpired { return "Expired" }
        if d == 0    { return "Expires today" }
        if d == 1    { return "Expires tomorrow" }
        return "Expires in \(d) days"
    }

    var expiryColour: String {
        if isExpired        { return "red" }
        if daysUntilExpiry <= 1 { return "orange" }
        return "green"
    }
}

// MARK: - Bridging to StoredIngredient

extension LeftoverItem.LeftoverDestination {
    /// Location label used when a leftover is stored as a StoredIngredient.
    var locationValue: String {
        switch self {
        case .ownFridge:    return "Fridge"
        case .sharedFridge: return "Shared"
        case .freezer:      return "Freezer"
        }
    }

    init(location: String) {
        let l = location.lowercased()
        if l.contains("freez") {
            self = .freezer
        } else if l.contains("shared") {
            self = .sharedFridge
        } else {
            self = .ownFridge
        }
    }
}

extension LeftoverItem {
    /// Build a leftover view-model from a stored inventory item.
    init(stored: StoredIngredient) {
        self.init(
            id: stored.id,
            recipeName: stored.name,
            cookedDate: Date(),            // not persisted; not surfaced in the UI
            expiryDate: stored.expirationDate,
            portionsRemaining: Int(stored.quantity) ?? 1,
            destination: LeftoverDestination(location: stored.location)
        )
    }
}

// MARK: - Manager

@MainActor
final class LeftoverManager: ObservableObject {

    static let shared = LeftoverManager()

    /// Leftovers are stored as `.leftover` items inside FrydgeManager so they sync via
    /// CloudKit and live alongside the rest of the fridge. This type is now a thin facade
    /// that maps between the leftover UI and the shared inventory store.
    private var frydge: FrydgeManager { FrydgeManager.shared }

    init() {}

    // MARK: - Derived collections

    var items: [LeftoverItem] {
        frydge.leftovers.map(LeftoverItem.init(stored:))
    }

    var activeItems: [LeftoverItem] {
        items.filter { !$0.isExpired }.sorted { $0.expiryDate < $1.expiryDate }
    }

    // MARK: - CRUD (forwarded to FrydgeManager)

    func add(_ item: LeftoverItem) {
        frydge.addLeftover(
            id: item.id,
            recipeName: item.recipeName,
            portions: item.portionsRemaining,
            expiryDate: item.expiryDate,
            location: item.destination.locationValue
        )
    }

    func remove(id: UUID) {
        frydge.deleteItem(byID: id)
    }

    func updatePortions(id: UUID, portions: Int) {
        frydge.setLeftoverPortions(id: id, portions: portions)
    }

    func purgeExpired() {
        frydge.purgeExpiredLeftovers()
    }

    // MARK: - Notification scheduling

    /// Schedule the "did you have leftovers?" notification 1 hour after cooking ends.
    static func scheduleLeftoverCheck(recipeName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Leftovers from \(recipeName)?"
        content.body  = "Got any left? Tap to store them in your fridge before they're forgotten."
        content.sound = .default
        content.categoryIdentifier = LeftoverNotification.categoryID

        // Pass the recipe name through so the app knows which recipe to pre-fill.
        content.userInfo = [LeftoverNotification.recipeNameKey: recipeName]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * 60, repeats: false)
        let id = "\(LeftoverNotification.requestPrefix)\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Leftovers] Failed to schedule notification: \(error)")
            } else {
                print("[Leftovers] Scheduled leftover check for '\(recipeName)' in 1 hour.")
            }
        }
    }

    // MARK: - Shared fridge notification

    /// Post a CloudKit notification to shared fridge members when leftovers go into the shared fridge.
    static func notifySharedFridgeMembers(leftover: LeftoverItem) async {
        // Post a local notification on this device — CloudKit push to members
        // would require a subscription per shared zone. For now, post a silent
        // CloudKit record change that the shared fridge subscription will pick up.
        // This mirrors the pattern used by SharedFridgeManager.
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let db = container.sharedCloudDatabase

        let record = CKRecord(recordType: "LeftoverNotice")
        record["recipeName"]       = leftover.recipeName as CKRecordValue
        record["portionsRemaining"] = leftover.portionsRemaining as CKRecordValue
        record["expiryDate"]       = leftover.expiryDate as CKRecordValue
        record["destination"]      = leftover.destination.rawValue as CKRecordValue

        do {
            _ = try await db.save(record)
            print("[Leftovers] Shared fridge notified about '\(leftover.recipeName)'.")
        } catch {
            print("[Leftovers] CloudKit notice failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Notification constants

enum LeftoverNotification {
    static let categoryID    = "LEFTOVER_CHECK"
    static let actionStore   = "LEFTOVER_STORE"
    static let actionEaten   = "LEFTOVER_EATEN"
    static let recipeNameKey = "leftoverRecipeName"
    static let requestPrefix = "frydge.leftover."

    static var category: UNNotificationCategory {
        let store = UNNotificationAction(
            identifier: actionStore,
            title: "Store leftovers",
            options: [.foreground]
        )
        let eaten = UNNotificationAction(
            identifier: actionEaten,
            title: "All eaten",
            options: []
        )
        return UNNotificationCategory(
            identifier: categoryID,
            actions: [store, eaten],
            intentIdentifiers: [],
            options: []
        )
    }
}
