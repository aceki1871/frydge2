//
//  CommunityPhoto.swift
//  FrydgeRecipes
//
//  A product/ingredient photo contributed by a Frydge user and visible to every
//  other user. Fills gaps where the automated image search (ProductImageCacheManager)
//  finds nothing, or finds something generic/wrong — contributing is an explicit,
//  opt-in action, separate from the private, local-only UserPhotoLibrary.
//

import Foundation
import CloudKit
import UIKit

struct CommunityPhoto: Identifiable {
    static let recordType = "CommunityPhoto"
    /// Auto-hide kicks in once this many *distinct* users have reported a photo.
    static let autoHideThreshold = 3

    let id: CKRecord.ID
    /// GTIN/barcode when the contributor scanned or matched one — the precise key.
    /// `nil` falls back to `nameKey`, which is always set.
    let barcode: String?
    let nameKey: String
    let image: UIImage
    /// CloudKit user record name of the contributor — lets them remove their own
    /// photo later and keeps a report from hiding someone else's upload by mistake.
    let contributorID: String
    let createdAt: Date
    /// Distinct reporter IDs. The record is never auto-deleted (so abuse can still
    /// be audited), just excluded from fetch results once past the threshold.
    let reporterIDs: [String]

    var isHidden: Bool { reporterIDs.count >= CommunityPhoto.autoHideThreshold }

    static func normalizedNameKey(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(record: CKRecord) {
        guard let nameKey = record["nameKey"] as? String,
              let contributorID = record["contributorID"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let asset = record["image"] as? CKAsset,
              let fileURL = asset.fileURL,
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.display) else { return nil }

        self.id = record.recordID
        self.barcode = record["barcode"] as? String
        self.nameKey = nameKey
        self.image = image
        self.contributorID = contributorID
        self.createdAt = createdAt
        self.reporterIDs = record["reporterIDs"] as? [String] ?? []
    }
}
