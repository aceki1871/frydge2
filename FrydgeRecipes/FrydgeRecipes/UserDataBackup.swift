//
//  UserDataBackup.swift
//  FrydgeRecipes
//
//  One-file JSON backup of everything personal the app holds locally: fridge
//  and leftover items, the shopping list, dietary rules, the coarse dietary
//  tags, favourite recipe IDs and the profile name. Profile → Your Data
//  exports it to Files / AirDrop and imports it back (merging, never wiping).
//
//  Recipes are deliberately not in here: they already live in the user's
//  private CloudKit database and are restored by signing in to iCloud.
//
//  Photos are not in here either. The exported `StoredIngredient` /
//  `ShoppingListItem` structs carry an empty `userPhotoData`: per-item photos
//  live as `CDItemPhoto` rows that CloudKit syncs, and the device-local
//  `UserPhotoLibrary` cache is re-seeded from them on demand
//  (`UserPhotoLibrary.photosWithSyncedFallback`). Community photos are public
//  records and never part of a personal backup. If photos are ever added to
//  this file they must be opt-in: a fridge with a few dozen photos would make
//  the export tens of megabytes.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Payload

struct FrydgeBackup: Codable {
    static let currentVersion = 1

    var version: Int = FrydgeBackup.currentVersion
    var exportedAt: Date = Date()
    var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    var profileName: String = ""
    /// "GF,DF,V,VG" style CSV, same shape ProfileView stores.
    var profileDietaryCSV: String = ""
    var dietaryRestrictions: [DietaryRestriction] = []
    var favouriteRecipeIDs: [String] = []

    /// Fridge *and* leftover items (`lifecycle` tells them apart).
    var fridgeItems: [StoredIngredient] = []
    var shoppingItems: [ShoppingListItem] = []

    var fridgeCount: Int { fridgeItems.filter { $0.lifecycle == .fridge }.count }
    var leftoverCount: Int { fridgeItems.filter { $0.lifecycle == .leftover }.count }
}

/// What an import actually changed, for the confirmation alert.
struct FrydgeBackupImportSummary {
    var fridgeAdded = 0
    var leftoversAdded = 0
    var shoppingAdded = 0
    var restrictionsAdded = 0
    var favouritesAdded = 0
    var profileNameRestored = false
    var dietaryTagsRestored = false

    var isEmpty: Bool {
        fridgeAdded == 0 && leftoversAdded == 0 && shoppingAdded == 0
            && restrictionsAdded == 0 && favouritesAdded == 0
            && !profileNameRestored && !dietaryTagsRestored
    }

    var message: String {
        if isEmpty { return "Everything in that file was already here — nothing to add." }
        var parts: [String] = []
        if fridgeAdded > 0 { parts.append("\(fridgeAdded) fridge item\(fridgeAdded == 1 ? "" : "s")") }
        if leftoversAdded > 0 { parts.append("\(leftoversAdded) leftover\(leftoversAdded == 1 ? "" : "s")") }
        if shoppingAdded > 0 { parts.append("\(shoppingAdded) shopping item\(shoppingAdded == 1 ? "" : "s")") }
        if restrictionsAdded > 0 { parts.append("\(restrictionsAdded) dietary rule\(restrictionsAdded == 1 ? "" : "s")") }
        if favouritesAdded > 0 { parts.append("\(favouritesAdded) favourite\(favouritesAdded == 1 ? "" : "s")") }
        if profileNameRestored { parts.append("your name") }
        if dietaryTagsRestored { parts.append("dietary preferences") }
        return "Added " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Build / restore

@MainActor
enum UserDataBackup {

    static let profileNameKey = "frydge.authorName"
    static let profileDietaryKey = DietaryRestrictionStore.profileTagsKey
    static let favouritesKey = "favoriteRecipeIDs"

    /// Snapshot of the current user's data.
    static func make(frydge: FrydgeManager, shopping: ShoppingListManager) -> FrydgeBackup {
        let defaults = UserDefaults.standard
        var backup = FrydgeBackup()
        backup.profileName = defaults.string(forKey: profileNameKey) ?? ""
        backup.profileDietaryCSV = defaults.string(forKey: profileDietaryKey) ?? ""
        backup.dietaryRestrictions = DietaryRestrictionStore.shared.restrictions
        backup.favouriteRecipeIDs = (defaults.string(forKey: favouritesKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        backup.fridgeItems = frydge.storedIngredients
        backup.shoppingItems = shopping.shoppingListItems
        return backup
    }

    static func encode(_ backup: FrydgeBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> FrydgeBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FrydgeBackup.self, from: data)
        } catch {
            // Older exports used the default (seconds-since-2001) date format.
            decoder.dateDecodingStrategy = .deferredToDate
            return try decoder.decode(FrydgeBackup.self, from: data)
        }
    }

    /// Merges a backup into the live stores. Nothing is deleted: items with
    /// an id already present are skipped, restrictions/favourites are
    /// unioned, and the profile name / tags are only filled in when empty.
    @discardableResult
    static func restore(
        _ backup: FrydgeBackup,
        into frydge: FrydgeManager,
        shopping: ShoppingListManager
    ) -> FrydgeBackupImportSummary {
        var summary = FrydgeBackupImportSummary()
        let defaults = UserDefaults.standard

        // Fridge + leftovers
        let fridgeOnly = backup.fridgeItems.filter { $0.lifecycle == .fridge }
        let leftoversOnly = backup.fridgeItems.filter { $0.lifecycle == .leftover }
        summary.fridgeAdded = frydge.restoreFromBackup(fridgeOnly)
        summary.leftoversAdded = frydge.restoreFromBackup(leftoversOnly)

        // Shopping list
        summary.shoppingAdded = shopping.restoreFromBackup(backup.shoppingItems)

        // Dietary rules
        for rule in backup.dietaryRestrictions {
            if DietaryRestrictionStore.shared.add(term: rule.term, severity: rule.severity, note: rule.note) {
                summary.restrictionsAdded += 1
            }
        }

        // Coarse tags (only when nothing is set locally, so we never downgrade)
        let currentTags = defaults.string(forKey: profileDietaryKey) ?? ""
        if currentTags.trimmingCharacters(in: .whitespaces).isEmpty, !backup.profileDietaryCSV.isEmpty {
            defaults.set(backup.profileDietaryCSV, forKey: profileDietaryKey)
            summary.dietaryTagsRestored = true
        }

        // Favourites (union)
        let existing = Set((defaults.string(forKey: favouritesKey) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let incoming = Set(backup.favouriteRecipeIDs)
        let merged = existing.union(incoming)
        if merged.count > existing.count {
            defaults.set(merged.sorted().joined(separator: ","), forKey: favouritesKey)
            summary.favouritesAdded = merged.count - existing.count
        }

        // Name (fill in only)
        let currentName = defaults.string(forKey: profileNameKey) ?? ""
        if currentName.trimmingCharacters(in: .whitespaces).isEmpty, !backup.profileName.isEmpty {
            defaults.set(backup.profileName, forKey: profileNameKey)
            RecipeAuthor.setName(backup.profileName)
            summary.profileNameRestored = true
        }

        return summary
    }

    static func defaultFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Frydge-Backup-\(f.string(from: Date()))"
    }
}

// MARK: - FileDocument

/// JSON file wrapper for `.fileExporter`. Declared on `.json` so Files shows
/// it with a sensible icon and other apps can open it.
struct FrydgeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
