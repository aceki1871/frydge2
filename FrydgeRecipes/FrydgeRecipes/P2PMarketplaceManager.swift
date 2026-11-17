//
//  P2PMarketplaceManager.swift
//  FrydgeRecipes
//
//  Created on 29/04/2026.
//

import SwiftUI
import CloudKit
import CoreLocation

// MARK: - P2P Listing Model

struct P2PListing: Identifiable, Codable {
    let id: UUID
    var title: String
    var description: String
    var price: Decimal
    var currency: String
    var sellerName: String
    /// MarketplaceIdentity.currentUserID of the seller — the same id their
    /// orders and Stripe Connect account are registered under.
    var sellerID: String
    var sellerStripeAccountId: String? // Stripe Connect acct_... ID (set after seller onboarding)
    var imageData: Data?
    var isAvailable: Bool
    var location: CLLocationCoordinate2D?
    var what3WordsLocation: String?   // e.g. "filled.count.soap" — ultra-precise pickup point
    var createdAt: Date
    var updatedAt: Date
    
    var formattedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: price as NSDecimalNumber) ?? "\(price)"
    }

    /// True when the seller gave buyers somewhere to collect from.
    var hasPickupLocation: Bool {
        location != nil || !(what3WordsLocation?.isEmpty ?? true)
    }

    /// Straight-line distance from the buyer, or nil when either side has no
    /// location. Metres under 1 km, otherwise one-decimal kilometres.
    func distance(from userLocation: CLLocation?) -> CLLocationDistance? {
        guard let userLocation, let location else { return nil }
        return userLocation.distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
    }

    func distanceText(from userLocation: CLLocation?) -> String? {
        guard let meters = distance(from: userLocation) else { return nil }
        if meters < 100 { return "Nearby" }
        if meters < 1000 { return "\(Int((meters / 50).rounded()) * 50) m" }
        return String(format: "%.1f km", meters / 1000)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, price, currency, sellerName, sellerID
        case sellerStripeAccountId, imageData, isAvailable, createdAt, updatedAt
        case locationLatitude, locationLongitude, what3WordsLocation
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        price: Decimal,
        currency: String = "NZD",
        sellerName: String,
        sellerID: String,
        sellerStripeAccountId: String? = nil,
        imageData: Data? = nil,
        isAvailable: Bool = true,
        location: CLLocationCoordinate2D? = nil,
        what3WordsLocation: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.price = price
        self.currency = currency
        self.sellerName = sellerName
        self.sellerID = sellerID
        self.sellerStripeAccountId = sellerStripeAccountId
        self.imageData = imageData
        self.isAvailable = isAvailable
        self.location = location
        self.what3WordsLocation = what3WordsLocation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        price = try container.decode(Decimal.self, forKey: .price)
        currency = try container.decode(String.self, forKey: .currency)
        sellerName = try container.decode(String.self, forKey: .sellerName)
        sellerID = try container.decode(String.self, forKey: .sellerID)
        sellerStripeAccountId = try container.decodeIfPresent(String.self, forKey: .sellerStripeAccountId)
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        what3WordsLocation = try container.decodeIfPresent(String.self, forKey: .what3WordsLocation)

        if let lat = try container.decodeIfPresent(Double.self, forKey: .locationLatitude),
           let lon = try container.decodeIfPresent(Double.self, forKey: .locationLongitude) {
            location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            location = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(price, forKey: .price)
        try container.encode(currency, forKey: .currency)
        try container.encode(sellerName, forKey: .sellerName)
        try container.encode(sellerID, forKey: .sellerID)
        try container.encodeIfPresent(sellerStripeAccountId, forKey: .sellerStripeAccountId)
        try container.encodeIfPresent(imageData, forKey: .imageData)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(what3WordsLocation, forKey: .what3WordsLocation)

        if let location = location {
            try container.encode(location.latitude, forKey: .locationLatitude)
            try container.encode(location.longitude, forKey: .locationLongitude)
        }
    }
}

// MARK: - P2P Marketplace Manager

@MainActor
class P2PMarketplaceManager: ObservableObject {
    @Published var listings: [P2PListing] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// iCloud account state. Browsing the public database never needs an
    /// account; creating, editing and buying do.
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    /// Listings this device has paid for. CloudKit only lets the record's
    /// creator write to it, so a buyer cannot flip `isAvailable` on the seller's
    /// record — instead the purchase is remembered here and overlaid on fetch.
    @Published private(set) var purchasedListingIDs: Set<String>
    
    private let container: CKContainer
    private let database: CKDatabase
    private let recordType = "P2PListing"
    private static let purchasedKey = "marketplace.purchasedListingIDs"

    /// True when the user can post and manage listings.
    var canSell: Bool { accountStatus == .available && MarketplaceIdentity.currentUserID != nil }

    /// Listings posted from this account (including ones created before
    /// identity was unified, matched via legacy ids).
    var myListings: [P2PListing] { listings.filter(MarketplaceIdentity.owns) }
    
    init() {
        self.container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        self.database = container.publicCloudDatabase
        self.purchasedListingIDs = Set(UserDefaults.standard.stringArray(forKey: Self.purchasedKey) ?? [])
        
        print("[P2PMarketplace] 📦 Using container: \(container.containerIdentifier ?? "unknown")")
        
        Task { await refreshAccountStatus() }
    }

    func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
            print("[P2PMarketplace] iCloud account status: \(accountStatus.rawValue)")
        } catch {
            print("[P2PMarketplace] ❌ Error checking iCloud status: \(error)")
        }
    }

    /// Why selling is blocked right now, phrased for the user. Nil when it isn't.
    var sellingBlockedReason: String? {
        switch accountStatus {
        case .available:
            return MarketplaceIdentity.currentUserID == nil
                ? "Frydge is still connecting to iCloud. Try again in a moment."
                : nil
        case .noAccount:
            return "Sign in to iCloud in Settings to list items for sale. You can browse without signing in."
        case .restricted:
            return "iCloud access is restricted on this device, so listings can't be created."
        case .temporarilyUnavailable, .couldNotDetermine:
            return "iCloud isn't reachable right now. Check your connection and try again."
        @unknown default:
            return "iCloud isn't available right now."
        }
    }
    
    // MARK: - Fetch Listings
    
    func fetchListings() async {
        isLoading = true
        errorMessage = nil

        do {
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: recordType, predicate: predicate)
            let results = try await database.records(matching: query)

            var fetchedListings: [P2PListing] = []
            for (_, result) in results.matchResults {
                switch result {
                case .success(let record):
                    if let listing = decode(record: record) {
                        fetchedListings.append(listing)
                    }
                case .failure(let error):
                    print("[P2PMarketplace] Record fetch error: \(error)")
                }
            }
            listings = applyPurchaseOverlay(fetchedListings).sorted { $0.createdAt > $1.createdAt }

        } catch let ckError as CKError {
            switch ckError.code {
            case .unknownItem:
                // Record type not yet in schema — bootstrap it automatically.
                await initializeSchemaIfNeeded()
            case .notAuthenticated, .permissionFailure:
                // Public reads don't need an account; if we land here the
                // container itself is refusing us. Say so without blaming sign-in.
                errorMessage = "The marketplace couldn't be reached. Please try again later."
                print("[P2PMarketplace] Auth error: \(ckError.localizedDescription)")
            case .networkUnavailable, .networkFailure:
                // Keep showing cached listings on network failure
                if listings.isEmpty {
                    errorMessage = "You're offline. Connect to the internet to see what's for sale."
                }
                print("[P2PMarketplace] Network unavailable — showing cached listings")
            default:
                errorMessage = ckError.localizedDescription
                print("[P2PMarketplace] CloudKit error (\(ckError.code.rawValue)): \(ckError.localizedDescription)")
            }
        } catch {
            print("[P2PMarketplace] Unexpected error: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
    
    // MARK: - Add Listing
    
    func addListing(_ listing: P2PListing) async throws {
        print("[P2PMarketplace] 📝 Adding listing: \(listing.title)")
        
        // Create record with explicit ID to match listing's UUID
        let recordID = CKRecord.ID(recordName: listing.id.uuidString)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        await encode(listing: listing, to: record)
        
        // Optimistic update — show listing immediately before CloudKit round-trip
        listings.insert(listing, at: 0)

        do {
            _ = try await database.save(record)
            print("[P2PMarketplace] ✅ Successfully saved listing")
        } catch let error as CKError {
            // Roll back the optimistic insert on failure
            listings.removeAll { $0.id == listing.id }
            print("[P2PMarketplace] ❌ CloudKit Error: \(error.localizedDescription)")
            print("[P2PMarketplace] ❌ Error Code: \(error.code.rawValue)")
            if let underlyingError = error.userInfo[NSUnderlyingErrorKey] {
                print("[P2PMarketplace] ❌ Underlying Error: \(underlyingError)")
            }
            throw Self.userFacing(error)
        } catch {
            listings.removeAll { $0.id == listing.id }
            print("[P2PMarketplace] ❌ Unknown Error: \(error)")
            throw error
        }
    }
    
    // MARK: - Update Listing
    
    func updateListing(_ listing: P2PListing) async throws {
        // Fetch existing record first
        let recordID = CKRecord.ID(recordName: listing.id.uuidString)
        do {
            let record = try await database.record(for: recordID)
            await encode(listing: listing, to: record)
            _ = try await database.save(record)
        } catch let error as CKError {
            throw Self.userFacing(error)
        }

        // Patch in place rather than re-downloading every listing and its photo.
        if let index = listings.firstIndex(where: { $0.id == listing.id }) {
            listings[index] = listing
        } else {
            listings.insert(listing, at: 0)
        }
    }

    /// Flip a listing to sold. Only the creator may write the record, so this
    /// is for the seller's own listings (Tap to Pay, manual toggle, order sync).
    func markSold(_ listing: P2PListing) async throws {
        guard listing.isAvailable else { return }
        var updated = listing
        updated.isAvailable = false
        updated.updatedAt = Date()
        try await updateListing(updated)
    }

    /// Remember that this device bought the listing so it shows as sold here
    /// straight away, and update the record too when we happen to own it
    /// (debug self-purchases).
    func recordPurchase(of listing: P2PListing) async {
        purchasedListingIDs.insert(listing.id.uuidString)
        UserDefaults.standard.set(Array(purchasedListingIDs), forKey: Self.purchasedKey)
        if let index = listings.firstIndex(where: { $0.id == listing.id }) {
            listings[index].isAvailable = false
        }
        if MarketplaceIdentity.owns(listing) {
            try? await markSold(listing)
        }
    }

    /// Seller-side reconciliation: a buyer cannot modify the seller's CloudKit
    /// record, but the order server knows what has been paid for. Any of our
    /// listings with a paid order is flipped to sold here.
    func reconcileSoldListings(with sellerOrders: [MarketplaceOrder]) async {
        let soldIDs = Set(sellerOrders.compactMap { order -> String? in
            switch order.status {
            case .paid, .ready, .received: return order.listingId
            default: return nil
            }
        })
        guard !soldIDs.isEmpty else { return }
        for listing in myListings where listing.isAvailable && soldIDs.contains(listing.id.uuidString) {
            try? await markSold(listing)
        }
    }

    private func applyPurchaseOverlay(_ fetched: [P2PListing]) -> [P2PListing] {
        guard !purchasedListingIDs.isEmpty else { return fetched }
        return fetched.map { listing in
            guard purchasedListingIDs.contains(listing.id.uuidString) else { return listing }
            var copy = listing
            copy.isAvailable = false
            return copy
        }
    }
    
    // MARK: - Delete Listing
    
    func deleteListing(_ listing: P2PListing) async throws {
        let recordID = CKRecord.ID(recordName: listing.id.uuidString)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError {
            throw Self.userFacing(error)
        }
        listings.removeAll { $0.id == listing.id }
    }

    // MARK: - Error wording

    /// CloudKit's own messages talk about "CKErrorDomain code 9". Translate the
    /// ones a seller will actually hit.
    private static func userFacing(_ error: CKError) -> Error {
        let message: String
        switch error.code {
        case .notAuthenticated:
            message = "Sign in to iCloud in Settings to manage listings."
        case .permissionFailure:
            message = "Only the person who posted this listing can change it."
        case .networkUnavailable, .networkFailure:
            message = "You're offline. Check your connection and try again."
        case .quotaExceeded:
            message = "Your iCloud storage is full, so the listing couldn't be saved."
        case .limitExceeded:
            message = "That photo is too large. Try a smaller one."
        default:
            return error
        }
        return NSError(domain: CKErrorDomain, code: error.code.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    // MARK: - Schema Bootstrap

    /// Saves a minimal seed record that covers every field, creating the CloudKit schema
    /// automatically (development: on first write; production: same). Deletes the seed
    /// immediately so no dummy data persists.
    private func initializeSchemaIfNeeded() async {
        print("[P2PMarketplace] 🔧 Bootstrapping P2PListing schema...")
        let seedID = CKRecord.ID(recordName: "schema-seed-\(UUID().uuidString)")
        let seed = CKRecord(recordType: recordType, recordID: seedID)

        // Populate every field so CloudKit registers the full schema in one save.
        seed["id"]                = seedID.recordName as CKRecordValue
        seed["title"]             = "Schema Seed" as CKRecordValue
        seed["description"]       = "Auto-generated to create the record type." as CKRecordValue
        seed["price"]             = NSDecimalNumber(value: 0.01)
        seed["currency"]          = "NZD" as CKRecordValue
        seed["sellerName"]        = "System" as CKRecordValue
        seed["sellerID"]          = "system" as CKRecordValue
        seed["isAvailable"]       = NSNumber(value: false)
        seed["createdAt"]         = Date() as CKRecordValue
        seed["updatedAt"]         = Date() as CKRecordValue
        seed["what3WordsLocation"] = "index.home.raft" as CKRecordValue

        do {
            _ = try await database.save(seed)
            print("[P2PMarketplace] ✅ Schema created — deleting seed record")
            _ = try? await database.deleteRecord(withID: seedID)
            listings = []
        } catch {
            print("[P2PMarketplace] ❌ Schema bootstrap failed: \(error.localizedDescription)")
            // Not authenticated or network down — show empty marketplace, no error banner.
            listings = []
        }
        isLoading = false
    }

    // MARK: - CloudKit Encoding/Decoding
    
    private func encode(listing: P2PListing, to record: CKRecord) async {
        record["id"] = listing.id.uuidString
        record["title"] = listing.title
        record["description"] = listing.description
        record["price"] = listing.price as NSDecimalNumber
        record["currency"] = listing.currency
        record["sellerName"] = listing.sellerName
        record["sellerID"] = listing.sellerID
        record["isAvailable"] = NSNumber(value: listing.isAvailable)
        record["createdAt"] = listing.createdAt
        record["updatedAt"] = listing.updatedAt
        // Bank details were once written here for a QR payment flow that no
        // longer exists. Payments go through Stripe, so the public record must
        // never carry them again — clear anything left on older listings.
        record["sellerBankAccount"] = nil

        // Store image as CKAsset (no 1MB record-field limit).
        // Compression re-encodes a large photo several times — run it off the
        // main actor so posting a listing doesn't freeze the UI.
        if let imageData = listing.imageData {
            let listingID = listing.id
            let assetURL: URL? = await Task.detached(priority: .userInitiated) {
                let compressed = Self.compressImageData(imageData, maxBytes: 8_000_000)
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(listingID.uuidString + "_img.jpg")
                return (try? compressed.write(to: tmpURL)) != nil ? tmpURL : nil
            }.value
            if let assetURL {
                record["image"] = CKAsset(fileURL: assetURL)
            }
        } else {
            record["image"] = nil
        }

        if let location = listing.location {
            record["location"] = CLLocation(latitude: location.latitude, longitude: location.longitude)
        } else {
            record["location"] = nil
        }
        record["what3WordsLocation"] = listing.what3WordsLocation
    }

    /// Compress image data to JPEG, reducing quality until it fits under maxBytes.
    private nonisolated static func compressImageData(_ data: Data, maxBytes: Int) -> Data {
        guard let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload) else { return data }
        var quality: CGFloat = 0.85
        while quality > 0.1 {
            if let jpeg = image.jpegData(compressionQuality: quality) {
                if jpeg.count <= maxBytes { return jpeg }
            }
            quality -= 0.15
        }
        return image.jpegData(compressionQuality: 0.1) ?? data
    }

    private func decode(record: CKRecord) -> P2PListing? {
        // Use recordID.recordName as fallback id so records without an explicit "id" field still decode
        let idString = record["id"] as? String ?? record.recordID.recordName
        guard let id = UUID(uuidString: idString),
              let title = record["title"] as? String,
              let description = record["description"] as? String,
              let currency = record["currency"] as? String,
              let sellerName = record["sellerName"] as? String,
              let sellerID = record["sellerID"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else {
            print("[P2PMarketplace] ⚠️ Skipping record \(record.recordID.recordName) — missing required field")
            return nil
        }
        // CloudKit returns NSNumber for numeric fields; NSDecimalNumber cast can silently fail
        let priceNumber = record["price"] as? NSNumber ?? NSNumber(value: 0)
        let price = Decimal(string: priceNumber.stringValue) ?? Decimal(priceNumber.doubleValue)
        // CloudKit stores Bool as NSNumber (Int64)
        let isAvailable = (record["isAvailable"] as? NSNumber)?.boolValue ?? true

        // Read image from CKAsset
        var imageData: Data? = nil
        if let asset = record["image"] as? CKAsset, let url = asset.fileURL {
            imageData = try? Data(contentsOf: url)
        }

        var location: CLLocationCoordinate2D? = nil
        if let clLocation = record["location"] as? CLLocation {
            location = clLocation.coordinate
        }
        let what3WordsLocation = record["what3WordsLocation"] as? String

        return P2PListing(
            id: id,
            title: title,
            description: description,
            price: price,
            currency: currency,
            sellerName: sellerName,
            sellerID: sellerID,
            imageData: imageData,
            isAvailable: isAvailable,
            location: location,
            what3WordsLocation: what3WordsLocation,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
