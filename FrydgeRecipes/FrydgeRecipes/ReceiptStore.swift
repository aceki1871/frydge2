//
//  ReceiptStore.swift
//  FrydgeRecipes
//
//  Persists scanned shopping receipts to the user's private CloudKit database so
//  spend history syncs across their devices, and exposes simple budget/spend
//  aggregates for the Profile screen.
//
//  CloudKit setup (one-time, in the CloudKit Dashboard for
//  container "iCloud.com.Clark-Online.Recipe"):
//    • Record type "Receipt" with fields:
//        date (Date/Time), storeName (String), total (Double),
//        currencyCode (String), itemCount (Int64), itemsJSON (String)
//    • Make `date` a QUERYABLE index (needed for the fetch/sort), and
//      `recordName` queryable (needed for the TRUEPREDICATE fetch).
//    • Deploy the schema to Production before shipping.
//  Until that exists the store simply stays empty (it never crashes).
//

import Foundation
import CloudKit

struct Receipt: Identifiable, Hashable {
    let id: String            // CKRecord.recordID.recordName
    var date: Date
    var storeName: String?
    var total: Double         // in dollars
    var currencyCode: String
    var itemCount: Int
    var items: [String]       // human-readable lines, e.g. "2 x Milk"

    var totalText: String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currencyCode
        return nf.string(from: NSNumber(value: total)) ?? String(format: "$%.2f", total)
    }
}

@MainActor
final class ReceiptStore: ObservableObject {
    static let shared = ReceiptStore()

    @Published private(set) var receipts: [Receipt] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// iCloud account switched while installed: receipts live in the private
    /// database, so the cached list belongs to the previous account. Clear it
    /// and reload as the new account.
    func clearForAccountChange() {
        receipts = []
        lastError = nil
        Task { await load() }
    }

    private let database = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe").privateCloudDatabase
    private let recordType = "Receipt"

    private init() {}

    // MARK: - Spend aggregates

    /// Total spend within the current calendar month.
    var thisMonthTotal: Double {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return 0 }
        return total(in: interval)
    }

    /// Total spend within an arbitrary interval.
    func total(in interval: DateInterval) -> Double {
        receipts
            .filter { interval.contains($0.date) }
            .reduce(0) { $0 + $1.total }
    }

    var allTimeTotal: Double { receipts.reduce(0) { $0 + $1.total } }

    // MARK: - CRUD

    func save(storeName: String?, total: Double, currencyCode: String = "NZD", items: [String]) async {
        let record = CKRecord(recordType: recordType)
        record["date"] = Date() as CKRecordValue
        if let storeName, !storeName.isEmpty { record["storeName"] = storeName as CKRecordValue }
        record["total"] = total as CKRecordValue
        record["currencyCode"] = currencyCode as CKRecordValue
        record["itemCount"] = items.count as CKRecordValue
        if let data = try? JSONEncoder().encode(items),
           let json = String(data: data, encoding: .utf8) {
            record["itemsJSON"] = json as CKRecordValue
        }

        do {
            let saved = try await database.save(record)
            let receipt = Self.receipt(from: saved)
            receipts.insert(receipt, at: 0)
            receipts.sort { $0.date > $1.date }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[ReceiptStore] save failed: \(error.localizedDescription)")
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        do {
            // Follow the cursor so an archive beyond one page is complete.
            let records = try await database.allRecords(matching: query)
            let loaded: [Receipt] = records.map { Self.receipt(from: $0) }
            receipts = loaded.sorted { $0.date > $1.date }
            lastError = nil
        } catch {
            // Most common cause on a fresh install: the "Receipt" schema / index
            // isn't provisioned yet. Stay empty rather than surface a scary error.
            lastError = error.localizedDescription
            print("[ReceiptStore] load failed: \(error.localizedDescription)")
        }
    }

    func delete(_ receipt: Receipt) async {
        let id = CKRecord.ID(recordName: receipt.id)
        do {
            _ = try await database.deleteRecord(withID: id)
            receipts.removeAll { $0.id == receipt.id }
        } catch {
            lastError = error.localizedDescription
            print("[ReceiptStore] delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Mapping

    private static func receipt(from record: CKRecord) -> Receipt {
        var items: [String] = []
        if let json = record["itemsJSON"] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            items = decoded
        }
        return Receipt(
            id: record.recordID.recordName,
            date: (record["date"] as? Date) ?? record.creationDate ?? Date(),
            storeName: record["storeName"] as? String,
            total: (record["total"] as? Double) ?? 0,
            currencyCode: (record["currencyCode"] as? String) ?? "NZD",
            itemCount: (record["itemCount"] as? Int) ?? items.count,
            items: items
        )
    }
}
