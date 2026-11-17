//
//  WidgetPriceFetcher.swift
//  FrydgeRecipes
//
//  Eagerly fetches the cheapest known price for each item in the widget snapshot
//  (top 10 from the shopping list) and writes them back into the snapshot so the
//  home/lock-screen widgets render with prices and can total the basket.
//
//  Uses the existing grocery-price-server Cloudflare worker — same endpoint the
//  ProductDetailsView availability flow uses.
//

import Foundation

actor WidgetPriceFetcher {
    static let shared = WidgetPriceFetcher()

    private struct CacheEntry {
        let priceText: String?
        let storeName: String?
        let priceValue: Double?
        let currencyCode: String?
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: Set<String> = []
    private let freshness: TimeInterval = 60 * 60 * 6 // 6 hours

    /// Refreshes prices for the given snapshot items. Items already priced and fresh are skipped.
    func refresh(for items: [WidgetSnapshotItem]) async {
        guard !items.isEmpty else { return }

        let now = Date()
        let needsFetch = items.filter { item in
            let key = item.name.lowercased()
            if inFlight.contains(key) { return false }
            if let entry = cache[key], now.timeIntervalSince(entry.fetchedAt) < freshness {
                return false
            }
            return true
        }

        guard !needsFetch.isEmpty else {
            applyCacheToSnapshot()
            return
        }

        for item in needsFetch {
            inFlight.insert(item.name.lowercased())
        }

        let preferredStoreName = WidgetSnapshot.read().nearestStoreName

        await withTaskGroup(of: (String, PriceResult?).self) { group in
            for item in needsFetch {
                group.addTask { [weak self] in
                    guard let self else { return (item.name.lowercased(), nil) }
                    let result = await self.fetchBestPrice(for: item.name, preferredStoreName: preferredStoreName)
                    return (item.name.lowercased(), result)
                }
            }

            for await (key, result) in group {
                cache[key] = CacheEntry(
                    priceText: result?.priceText,
                    storeName: result?.storeName,
                    priceValue: result?.priceValue,
                    currencyCode: result?.currencyCode,
                    fetchedAt: Date()
                )
                inFlight.remove(key)
            }
        }

        applyCacheToSnapshot()
    }

    private func applyCacheToSnapshot() {
        let cache = self.cache
        WidgetSnapshot.mutate { snap in
            snap.items = snap.items.map { item in
                var copy = item
                if let entry = cache[item.name.lowercased()] {
                    copy.priceText = entry.priceText
                    copy.priceStoreName = entry.storeName
                    copy.priceValue = entry.priceValue
                    copy.currencyCode = entry.currencyCode
                }
                return copy
            }
        }
    }

    private func fetchBestPrice(for name: String, preferredStoreName: String?) async -> PriceResult? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://grocery-price-server.davekitson-read.workers.dev/search-products?q=\(encoded)&limit=5") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            let pricedProducts = decoded.products.filter { $0.price != nil }
            guard !pricedProducts.isEmpty else { return nil }

            let preferredStore = preferredStoreName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredProducts = pricedProducts.filter { product in
                guard let preferredStore, !preferredStore.isEmpty, let storeName = product.storeName else { return false }
                return Self.normalized(storeName).contains(Self.normalized(preferredStore))
                    || Self.normalized(preferredStore).contains(Self.normalized(storeName))
            }

            let best = (preferredProducts.isEmpty ? pricedProducts : preferredProducts)
                .min { ($0.price ?? .greatestFiniteMagnitude) < ($1.price ?? .greatestFiniteMagnitude) }

            guard let best, let price = best.price else { return nil }
            let currency = best.currencyCode ?? "NZD"
            return PriceResult(
                priceText: formatPrice(price, currencyCode: currency),
                storeName: best.storeName,
                priceValue: price,
                currencyCode: currency
            )
        } catch {
            return nil
        }
    }

    private func formatPrice(_ price: Double, currencyCode: String) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currencyCode
        nf.maximumFractionDigits = 2
        nf.minimumFractionDigits = 2
        return nf.string(from: NSNumber(value: price)) ?? String(format: "$%.2f", price)
    }

    private struct SearchResponse: Decodable {
        let products: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let name: String
        let price: Double?
        let currencyCode: String?
        let storeName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case price
            case currencyCode
            case currency_code
            case storeName
            case store
            case store_name
            case retailer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            price = Self.decodePrice(from: container)
            currencyCode = (try? container.decode(String.self, forKey: .currencyCode))
                ?? (try? container.decode(String.self, forKey: .currency_code))
            storeName = (try? container.decode(String.self, forKey: .storeName))
                ?? (try? container.decode(String.self, forKey: .store))
                ?? (try? container.decode(String.self, forKey: .store_name))
                ?? (try? container.decode(String.self, forKey: .retailer))
        }

        private static func decodePrice(from container: KeyedDecodingContainer<CodingKeys>) -> Double? {
            if let value = try? container.decode(Double.self, forKey: .price) {
                return value
            }

            if let value = try? container.decode(String.self, forKey: .price) {
                let cleaned = value.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
                return Double(cleaned)
            }

            return nil
        }
    }

    private struct PriceResult {
        let priceText: String
        let storeName: String?
        let priceValue: Double
        let currencyCode: String
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
