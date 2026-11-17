//
//  CommunityPhotoStore.swift
//  FrydgeRecipes
//
//  Shared, all-users-visible photo pool for products/ingredients. Keyed by
//  barcode when a contributor has one (precise — no collisions across different
//  real products), falling back to a normalized name for generic items.
//
//  NOTE: before shipping, mark `barcode`, `nameKey` and `createdAt` as queryable
//  (and `createdAt` sortable) for the CommunityPhoto record type in the CloudKit
//  Dashboard schema — the client-side queries below require those indexes.
//

import Foundation
import CloudKit
import UIKit

enum CommunityPhotoError: Error {
    case invalidImage
}

@MainActor
final class CommunityPhotoStore {
    static let shared = CommunityPhotoStore()

    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
    private var database: CKDatabase { container.publicCloudDatabase }

    /// Per-process memo of fetch results, keyed the same way as the CloudKit query
    /// itself so a report/upload can precisely invalidate just that entry.
    private var memoryCache: [String: [CommunityPhoto]] = [:]

    private init() {}

    // MARK: - Fetch

    /// Non-hidden community photos for an item, newest first. Barcode match when
    /// known; otherwise the normalized name. Memoised per process — a newly
    /// reported/hidden photo won't reappear until the app restarts.
    func photos(barcode: String?, name: String) async -> [CommunityPhoto] {
        let nameKey = CommunityPhoto.normalizedNameKey(name)
        let cacheKey = (barcode?.isEmpty == false) ? "barcode:\(barcode!)" : "name:\(nameKey)"
        if let cached = memoryCache[cacheKey] { return cached }

        let predicate: NSPredicate
        if let barcode, !barcode.isEmpty {
            predicate = NSPredicate(format: "barcode == %@", barcode)
        } else {
            predicate = NSPredicate(format: "nameKey == %@", nameKey)
        }
        let query = CKQuery(recordType: CommunityPhoto.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let (matchResults, _) = try await database.records(matching: query, resultsLimit: 20)
            var fetched: [CommunityPhoto] = []
            for (_, result) in matchResults {
                if case .success(let record) = result, let photo = CommunityPhoto(record: record) {
                    fetched.append(photo)
                }
            }
            let visible = fetched.filter { !$0.isHidden }
            memoryCache[cacheKey] = visible
            return visible
        } catch {
            print("[CommunityPhotoStore] fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Newest visible community photo, if any — the auto-fill fallback for
    /// thumbnails when nothing else (offer photo, stock photo) was found.
    func firstPhoto(barcode: String?, name: String) async -> CommunityPhoto? {
        await photos(barcode: barcode, name: name).first
    }

    // MARK: - Contribute

    @discardableResult
    func upload(_ image: UIImage, barcode: String?, name: String) async throws -> CommunityPhoto {
        guard let asset = image.toCKAsset() else { throw CommunityPhotoError.invalidImage }
        let contributorID = await currentUserID()

        let record = CKRecord(recordType: CommunityPhoto.recordType)
        record["nameKey"] = CommunityPhoto.normalizedNameKey(name) as CKRecordValue
        if let barcode, !barcode.isEmpty { record["barcode"] = barcode as CKRecordValue }
        record["image"] = asset
        record["contributorID"] = contributorID as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        record["reporterIDs"] = [] as CKRecordValue

        let saved = try await database.save(record)
        guard let photo = CommunityPhoto(record: saved) else { throw CommunityPhotoError.invalidImage }

        invalidateCache(barcode: photo.barcode, nameKey: photo.nameKey)
        return photo
    }

    // MARK: - Report / remove

    /// Records the current user's report against a photo; once enough distinct
    /// users have reported it, `photos(barcode:name:)` stops returning it.
    func report(_ photo: CommunityPhoto) async throws {
        let me = await currentUserID()
        guard !photo.reporterIDs.contains(me) else { return }

        let record = try await database.record(for: photo.id)
        var reporters = record["reporterIDs"] as? [String] ?? []
        reporters.append(me)
        record["reporterIDs"] = reporters as CKRecordValue
        _ = try await database.save(record)
        invalidateCache(barcode: photo.barcode, nameKey: photo.nameKey)
    }

    /// Deletes the photo outright, but only when the current user is the one who
    /// contributed it.
    func removeMine(_ photo: CommunityPhoto) async throws {
        let me = await currentUserID()
        guard photo.contributorID == me else { return }
        try await database.deleteRecord(withID: photo.id)
        invalidateCache(barcode: photo.barcode, nameKey: photo.nameKey)
    }

    // MARK: - Private

    private func invalidateCache(barcode: String?, nameKey: String) {
        if let barcode, !barcode.isEmpty { memoryCache.removeValue(forKey: "barcode:\(barcode)") }
        memoryCache.removeValue(forKey: "name:\(nameKey)")
    }

    private func currentUserID() async -> String {
        if let cached = UserDefaults.standard.string(forKey: "appleUserID"), !cached.isEmpty {
            return cached
        }
        if let rid = try? await container.userRecordID() {
            UserDefaults.standard.set(rid.recordName, forKey: "appleUserID")
            return rid.recordName
        }
        return "unknown"
    }
}
