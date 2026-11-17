//
//  MarketplaceIdentity.swift
//  FrydgeRecipes
//
//  One identity for everything a person does in the marketplace.
//
//  WHY THIS EXISTS
//  ---------------
//  Listings, orders and Stripe Connect onboarding each used to pick their own
//  idea of "who am I": listings took the clerk org id (or minted a random UUID
//  per listing), while orders and Connect used the CloudKit user record name.
//  The result was that a normal seller could never see "My Listings", could not
//  edit or delete what they posted, and the server could not match a listing's
//  seller to the payout account they had set up.
//
//  Everything now keys on the CloudKit user record name (`appleUserID`), which
//  FrydgeManager resolves once and caches. Older listings created under a clerk
//  org id are still recognised as the current user's via `legacyIDs`.
//

import Foundation

/// Main-actor because it reads FrydgeAPIService's published org, and every
/// caller (views, the marketplace manager) is already on the main actor.
@MainActor
enum MarketplaceIdentity {

    /// Keys written by FrydgeManager / ShoppingListManager once CloudKit has
    /// resolved the current user.
    private static let appleUserKey = "appleUserID"
    private static let sellerNameKey = "marketplace.sellerDisplayName"
    private static let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"

    /// The stable id shared by listings, orders and Stripe Connect.
    /// Nil until the user is signed in to iCloud and the record name is known.
    static var currentUserID: String? {
        let candidates = [
            UserDefaults.standard.string(forKey: appleUserKey),
            UserDefaults(suiteName: appGroupName)?.string(forKey: appleUserKey)
        ]
        for case let value? in candidates {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Placeholders written before CloudKit answered are not identities.
            if trimmed.isEmpty || trimmed == "local" || trimmed.hasPrefix("install_") { continue }
            return trimmed
        }
        return nil
    }

    /// Ids this device may have stamped on listings before identity was unified.
    static var legacyIDs: Set<String> {
        var ids = Set<String>()
        if let org = FrydgeAPIService.shared.currentOrg?.id, !org.isEmpty { ids.insert(org) }
        if let org = UserDefaults.standard.string(forKey: "frydge_clerk_orgId"), !org.isEmpty { ids.insert(org) }
        return ids
    }

    /// True when the listing belongs to the person using this device.
    static func owns(_ listing: P2PListing) -> Bool {
        if let me = currentUserID, listing.sellerID == me { return true }
        return legacyIDs.contains(listing.sellerID)
    }

    /// The name shown to buyers. Prefers what the seller last typed, then the
    /// name Apple handed back at sign-in, then the clerk org name.
    static var sellerDisplayName: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: sellerNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        let given = defaults.string(forKey: "appleGivenName") ?? ""
        let family = defaults.string(forKey: "appleFamilyName") ?? ""
        let appleName = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !appleName.isEmpty { return appleName }
        return FrydgeAPIService.shared.currentOrg?.name ?? ""
    }

    static func rememberSellerDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: sellerNameKey)
    }
}
