//
//  ObservedPriceStore.swift
//  FrydgeRecipes
//
//  A local record of prices the user has actually paid, harvested from scanned
//  receipts. These "observed" prices are real and recent, so the app can surface
//  informed pricing (and spotted deals) instantly without waiting on a live
//  retailer lookup. Stored in the shared app group so widgets can read it too.
//

import Foundation

struct ObservedPrice: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String            // display name as seen on the receipt
    var normalizedKey: String   // for matching
    var price: Double           // dollars, line price paid
    var store: String?
    var date: Date
    var promoText: String?      // deal note if it was on special

    var isSpecial: Bool { promoText != nil }

    var priceText: String {
        String(format: "$%.2f", price)
    }
}

@MainActor
final class ObservedPriceStore: ObservableObject {
    static let shared = ObservedPriceStore()

    @Published private(set) var records: [ObservedPrice] = [] {  // newest first
        didSet { latestMemo.removeAll() }
    }

    /// `latest(for:)` scans every record with per-record tokenising, and the
    /// shopping list calls it for every row on every redraw. Memoised per
    /// name until the records change.
    private var latestMemo: [String: ObservedPrice?] = [:]

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let key = "observedPriceRecordsJSON"
    private let maxRecords = 3000

    private init() { load() }

    // MARK: - Writing

    /// Records one observed price. Skips empty names / non-positive prices.
    func record(name: String, price: Double, store: String?, date: Date = Date(), promoText: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, price > 0 else { return }
        let entry = ObservedPrice(
            name: trimmed,
            normalizedKey: Self.normalize(trimmed),
            price: price,
            store: store,
            date: date,
            promoText: promoText
        )
        records.insert(entry, at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        scheduleSave()
    }

    /// Records several observed prices at once (e.g. a whole receipt).
    func record(_ entries: [(name: String, price: Double, promoText: String?)], store: String?, date: Date = Date()) {
        let mapped: [ObservedPrice] = entries.compactMap { e in
            let trimmed = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, e.price > 0 else { return nil }
            return ObservedPrice(
                name: trimmed,
                normalizedKey: Self.normalize(trimmed),
                price: e.price,
                store: store,
                date: date,
                promoText: e.promoText
            )
        }
        guard !mapped.isEmpty else { return }
        records.insert(contentsOf: mapped, at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        scheduleSave()
    }

    // MARK: - Reading

    /// The most recent observed price for a product name, matching first by exact
    /// normalized key, then by token overlap (so "Anchor Milk 2L" finds "milk").
    func latest(for name: String) -> ObservedPrice? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }

        if let exact = records.first(where: { $0.normalizedKey == key }) {
            return exact
        }

        let queryTokens = Set(key.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard !queryTokens.isEmpty else { return nil }
        // records are newest-first, so the first token match is the most recent.
        return records.first { rec in
            let recTokens = Set(rec.normalizedKey.split(separator: " ").map(String.init))
            return !queryTokens.isDisjoint(with: recTokens)
        }
    }

    /// Full price history for a product, newest first.
    func history(for name: String) -> [ObservedPrice] {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return [] }
        return records.filter { $0.normalizedKey == key }
    }

    /// Every record that plausibly refers to this product: exact key matches
    /// first, then token-overlap matches (so "Anchor Milk 2L" on a receipt
    /// counts for "milk"). Newest first. Used by the in-store availability
    /// resolver, which cares about *which store* the item was bought at.
    func matches(for name: String) -> [ObservedPrice] {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return [] }

        let exact = records.filter { $0.normalizedKey == key }
        let queryTokens = Set(key.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard !queryTokens.isEmpty else { return exact }

        let fuzzy = records.filter { rec in
            guard rec.normalizedKey != key else { return false }
            let recTokens = Set(rec.normalizedKey.split(separator: " ").map(String.init))
            return !queryTokens.isDisjoint(with: recTokens)
        }
        return exact + fuzzy
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : Character(" ") }
            .reduce("") { $0 + String($1) }
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupName) ?? .standard
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ObservedPrice].self, from: data) else { return }
        records = decoded
    }

    private var saveTask: Task<Void, Never>?

    /// Coalesces rapid mutations (e.g. every line of a receipt) into a single
    /// write, and encodes the ~3000-record array off the main actor so saving
    /// never janks scanning UI.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }

    private func flushNow() {
        let snapshot = records
        let suite = appGroupName
        let storageKey = key
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            (UserDefaults(suiteName: suite) ?? .standard).set(data, forKey: storageKey)
        }
    }
}
