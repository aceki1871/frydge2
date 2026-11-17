//
//  StockAvailability.swift
//  FrydgeRecipes
//
//  Updated: NZ retailer lookups use the deployed Cloudflare Worker.
//  UK retailers keep HTML scraping + JS-render fallback.
//  Worker enrichment now includes product URL, image URL, title and details text.
//

import Foundation
import WebKit
import CoreLocation

enum StockAvailability {

    // Providers read view-owned location managers, so both registration and
    // invocation must stay on the main actor, even when Engine requests them.
    @MainActor static var currentLocationProvider: @MainActor () -> CLLocationCoordinate2D? = { nil }
    static var searchRadiusKm: Double = 5.0
    static var onProximityStoreDetected: ((StoreOffer) -> Void)? = nil

    // MARK: - Public API

    static func checkAnyStoreAvailability(for rawQuery: String) async -> Bool {
        let offers = await fetchOffers(for: rawQuery)
        return offers.contains(where: { $0.isProbablyMatch })
    }

    static func fetchOffers(for rawQuery: String) async -> [StoreOffer] {
        await shared.fetchOffers(for: rawQuery)
    }

    /// Every chain's offers for the query, for callers that need to know
    /// *which stores* list a product rather than just the best price.
    ///
    /// `fetchOffers` collapses to a single offer when the user has saved a
    /// preferred product for the ingredient (see `IngredientProductCache`),
    /// which would make every other chain look like it doesn't stock the
    /// item. This variant always runs the full lookup; when a preferred
    /// product exists it's reported in the result so the caller can still
    /// favour it, and the flag tells the caller that the plain `fetchOffers`
    /// path would have short-circuited.
    static func fetchAllOffers(for rawQuery: String) async -> (offers: [StoreOffer], preferred: StoreOffer?) {
        let (cleanQuery, _) = GroceryQueryBuilder.build(from: rawQuery)
        let preferred = await IngredientProductCache.shared.preferred(for: cleanQuery)?.toStoreOffer()
        let offers = await shared.fetchOffers(for: rawQuery, bypassingPreferred: true)
        return (offers, preferred)
    }

    static func fetchPricedOffersOnly(for rawQuery: String) async -> [StoreOffer] {
        let offers = await fetchOffers(for: rawQuery)
        return offers.filter { $0.price != nil }
    }

    // MARK: - Models

    struct StoreOffer: Identifiable, Equatable {
        let id = UUID()
        let store: String
        let productURL: URL
        let currencyCode: String
        let price: Double?
        let promoText: String?
        let isProbablyMatch: Bool

        // Enrichment
        let storeCoordinate: CLLocationCoordinate2D?
        let distanceMeters: Double?
        let productTitle: String?
        let imageURL: URL?
        let detailsText: String?

        static func == (lhs: StoreOffer, rhs: StoreOffer) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Country detection

    enum RetailCountry {
        case nz, gb

        static func detect(preferredCoordinate: CLLocationCoordinate2D?) -> RetailCountry {
            if let coordinate = preferredCoordinate,
               let countryFromCoordinate = country(from: coordinate) {
                return countryFromCoordinate
            }

            let locale = Locale.autoupdatingCurrent

            let regionIdentifier: String? = {
                if #available(iOS 16.0, *) {
                    return locale.region?.identifier
                } else {
                    return locale.regionCode
                }
            }()

            let localeIdentifier = locale.identifier.uppercased()
            let currencyCode = locale.currency?.identifier.uppercased()
            let timeZoneID = TimeZone.autoupdatingCurrent.identifier.uppercased()

            let explicitGB = [
                regionIdentifier?.uppercased(),
                currencyCode
            ].contains(where: { value in
                guard let value else { return false }
                return value == "GB" || value == "UK" || value == "GBP"
            }) || localeIdentifier.contains("_GB") || localeIdentifier.contains("-GB")

            let explicitNZ = [
                regionIdentifier?.uppercased(),
                currencyCode
            ].contains(where: { value in
                guard let value else { return false }
                return value == "NZ" || value == "NZD"
            }) || localeIdentifier.contains("_NZ") || localeIdentifier.contains("-NZ") || timeZoneID.contains("AUCKLAND") || timeZoneID.contains("CHATHAM")

            if explicitNZ { return .nz }
            if explicitGB { return .gb }
            return .nz
        }

        private static func country(from coordinate: CLLocationCoordinate2D) -> RetailCountry? {
            let lat = coordinate.latitude
            let lon = coordinate.longitude

            // New Zealand + Chatham Islands (coarse bounds)
            if lat >= -53.5, lat <= -29.0, lon >= 166.0, lon <= 179.9 {
                return .nz
            }

            // Great Britain / UK mainland coarse bounds
            if lat >= 49.5, lat <= 61.5, lon >= -8.8, lon <= 2.5 {
                return .gb
            }

            return nil
        }
    }

    // MARK: - Internals

    private static let shared = Engine()

    /// Location part of the offer cache key.
    ///
    /// Worker results only change when the nearest branch changes, so the
    /// coordinate is snapped to a grid of roughly 2 km. The old 100 m
    /// rounding meant walking across a car park, or driving between shops,
    /// invalidated every item on the list and refetched the lot over
    /// cellular.
    static let locationCacheGridDegrees: Double = 0.02

    static func locationCacheKey(for coordinate: CLLocationCoordinate2D?) -> String {
        guard let c = coordinate else { return "n/a" }
        let lat = Int((c.latitude / locationCacheGridDegrees).rounded())
        let lon = Int((c.longitude / locationCacheGridDegrees).rounded())
        return "cell:\(lat),\(lon)"
    }

    private actor Engine {
        private let diskCacheTTL: TimeInterval = 60 * 60 * 12
        private var cache: [String: CacheEntry] = [:]
        private var inFlight: [String: Task<[StoreOffer], Never>] = [:]
        private var proximityNotifiedKeys: Set<String> = []
        private let cacheFileURL: URL

        private struct CacheEntry {
            let offers: [StoreOffer]
            let date: Date
        }

        private struct DiskCacheFile: Codable {
            let entries: [String: DiskCacheEntry]
        }

        private struct DiskCacheEntry: Codable {
            let offers: [DiskStoreOffer]
            let date: Date
        }

        private struct DiskStoreOffer: Codable {
            let store: String
            let productURL: String
            let currencyCode: String
            let price: Double?
            let promoText: String?
            let isProbablyMatch: Bool
            let storeLatitude: Double?
            let storeLongitude: Double?
            let distanceMeters: Double?
            let productTitle: String?
            let imageURL: String?
            let detailsText: String?
        }

        // Replace this if your Worker URL changes.
        private let workerBaseURL = "https://grocery-price-server.davekitson-read.workers.dev"

        init() {
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.cacheFileURL = cachesURL.appendingPathComponent("stock_availability_cache_v1.json")
            Task { await self.restoreDiskCache() }
        }

        private func restoreDiskCache() {
            guard let data = try? Data(contentsOf: cacheFileURL) else { return }
            guard let decoded = try? JSONDecoder().decode(DiskCacheFile.self, from: data) else { return }

            var restored: [String: CacheEntry] = [:]
            restored.reserveCapacity(decoded.entries.count)

            for (key, entry) in decoded.entries {
                let offers = entry.offers.compactMap { self.makeStoreOffer(from: $0) }
                guard !offers.isEmpty else { continue }
                restored[key] = CacheEntry(offers: offers, date: entry.date)
            }

            self.cache = restored
        }

        private func persistDiskCache() {
            let sortedEntries = cache
                .sorted { $0.value.date > $1.value.date }
                .prefix(300)

            var encodedEntries: [String: DiskCacheEntry] = [:]
            encodedEntries.reserveCapacity(sortedEntries.count)

            for (key, entry) in sortedEntries {
                let offers = entry.offers.map { self.makeDiskStoreOffer(from: $0) }
                encodedEntries[key] = DiskCacheEntry(offers: offers, date: entry.date)
            }

            let payload = DiskCacheFile(entries: encodedEntries)
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: cacheFileURL, options: [.atomic])
        }

        private func makeDiskStoreOffer(from offer: StoreOffer) -> DiskStoreOffer {
            DiskStoreOffer(
                store: offer.store,
                productURL: offer.productURL.absoluteString,
                currencyCode: offer.currencyCode,
                price: offer.price,
                promoText: offer.promoText,
                isProbablyMatch: offer.isProbablyMatch,
                storeLatitude: offer.storeCoordinate?.latitude,
                storeLongitude: offer.storeCoordinate?.longitude,
                distanceMeters: offer.distanceMeters,
                productTitle: offer.productTitle,
                imageURL: offer.imageURL?.absoluteString,
                detailsText: offer.detailsText
            )
        }

        private func makeStoreOffer(from offer: DiskStoreOffer) -> StoreOffer? {
            guard let productURL = URL(string: offer.productURL) else { return nil }

            let coordinate: CLLocationCoordinate2D? = {
                guard let lat = offer.storeLatitude, let lon = offer.storeLongitude else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }()

            let imageURL: URL? = {
                guard let raw = offer.imageURL else { return nil }
                return URL(string: raw)
            }()

            return StoreOffer(
                store: offer.store,
                productURL: productURL,
                currencyCode: offer.currencyCode,
                price: offer.price,
                promoText: offer.promoText,
                isProbablyMatch: offer.isProbablyMatch,
                storeCoordinate: coordinate,
                distanceMeters: offer.distanceMeters,
                productTitle: offer.productTitle,
                imageURL: imageURL,
                detailsText: offer.detailsText
            )
        }

        // MARK: UK endpoints only

        private enum FetchStrategy {
            case htmlScrape(positiveHints: [String], negativeHints: [String], allowJSRenderFallback: Bool)
        }

        private struct Endpoint {
            let store: String
            let currencyCode: String
            let buildURL: (String) -> URL?
            let strategy: FetchStrategy
        }

        private let ukEndpoints: [Endpoint] = [
            Endpoint(
                store: "Tesco",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                    return URL(string: "https://www.tesco.com/groceries/en-GB/search?query=\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["results", "product", "tesco"],
                    negativeHints: ["0 results", "no results"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "Sainsbury's",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
                    return URL(string: "https://www.sainsburys.co.uk/gol-ui/SearchResults/\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "sainsbury"],
                    negativeHints: ["no results", "0 results"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "Waitrose",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                    return URL(string: "https://www.waitrose.com/ecom/shop/search?searchTerm=\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "waitrose"],
                    negativeHints: ["0 results", "no results"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "M&S",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                    return URL(string: "https://www.marksandspencer.com/search?query=\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "marksandspencer"],
                    negativeHints: ["no results", "0 results"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "ASDA",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
                    return URL(string: "https://groceries.asda.com/search/\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "asda"],
                    negativeHints: ["no results", "0 results", "we couldn't find"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "Morrisons",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                    return URL(string: "https://groceries.morrisons.com/search?q=\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "morrisons"],
                    negativeHints: ["no results", "0 results", "we couldn't find"],
                    allowJSRenderFallback: true
                )
            ),
            Endpoint(
                store: "Iceland",
                currencyCode: "GBP",
                buildURL: { q in
                    guard let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                    return URL(string: "https://www.iceland.co.uk/search?q=\(e)")
                },
                strategy: .htmlScrape(
                    positiveHints: ["search", "results", "product", "iceland"],
                    negativeHints: ["no results", "0 results", "no search results"],
                    allowJSRenderFallback: true
                )
            )
        ]

        // MARK: - Fetch dispatch

        func fetchOffers(for rawQuery: String, bypassingPreferred: Bool = false) async -> [StoreOffer] {
            // 1. Clean the query and extract size hint
            let (cleanQuery, sizeHint) = GroceryQueryBuilder.build(from: rawQuery)
            let normalized = StockAvailability.normalize(cleanQuery)
            guard !normalized.isEmpty else { return [] }

            // 2. Check ingredient cache for preferred product. Skipped when the
            //    caller needs every chain's listing (in-store availability),
            //    because a single preferred offer says nothing about the others.
            if !bypassingPreferred,
               let cached = await IngredientProductCache.shared.preferred(for: cleanQuery),
               let offer = cached.toStoreOffer() {
                return [offer]
            }

            let coord = await MainActor.run {
                StockAvailability.currentLocationProvider()
            }
            let country = RetailCountry.detect(preferredCoordinate: coord)

            let cacheKey = "\(country)|\(normalized)|\(StockAvailability.locationCacheKey(for: coord))"

            // A cached answer is served for the full disk lifetime: the worker
            // keeps its own fresher cache, and the retailer prices this feeds
            // don't move within a shopping trip.
            if let entry = cache[cacheKey], Date().timeIntervalSince(entry.date) < diskCacheTTL {
                return entry.offers
            }

            if let existing = inFlight[cacheKey] {
                return await existing.value
            }

            let task = Task<[StoreOffer], Never> {
                // Gate the actual network work: refreshing a long shopping list
                // fires one fetch per item, and unbounded parallel lookups slow
                // every request down. Cache hits and in-flight joins skip this.
                await self.acquireFetchSlot()
                let fetched: [StoreOffer]?
                switch country {
                case .nz:
                    // 3. Pass clean query (not raw) to the worker
                    fetched = await self.fetchOffersFromWorker(for: cleanQuery, coordinate: coord)
                case .gb:
                    fetched = await self.performUKLookup(normalizedQuery: normalized)
                }
                self.releaseFetchSlot()

                // A dropped or timed-out request is not an answer. Caching it
                // as "no offers" made one cellular blip hide an item's prices
                // for the rest of the session, so fall back to whatever we
                // last knew (even if it's past its lifetime) and leave the
                // cache alone so the next refresh tries again.
                guard let offers = fetched else {
                    return self.cache[cacheKey]?.offers ?? []
                }

                // 4. Filter and rank using ProductMatcher
                let filteredOffers = self.filterUsableOffers(offers, query: cleanQuery, sizeHint: sizeHint)
                let sortedOffers = self.sortOffersByPrice(filteredOffers)
                self.storeCache(offers: sortedOffers, key: cacheKey)
                return sortedOffers
            }

            inFlight[cacheKey] = task
            let value = await task.value
            inFlight[cacheKey] = nil
            return value
        }

        // MARK: - Fetch concurrency gate

        private let maxConcurrentFetches = 6
        private var activeFetches = 0
        private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

        private func acquireFetchSlot() async {
            if activeFetches < maxConcurrentFetches {
                activeFetches += 1
                return
            }
            await withCheckedContinuation { fetchWaiters.append($0) }
            // Slot was handed over by releaseFetchSlot(), already counted.
        }

        private func releaseFetchSlot() {
            if fetchWaiters.isEmpty {
                activeFetches -= 1
            } else {
                // Hand the slot straight to the next waiter.
                fetchWaiters.removeFirst().resume()
            }
        }

        private func storeCache(offers: [StoreOffer], key: String) {
            cache[key] = CacheEntry(offers: offers, date: Date())
            if cache.count > 500 {
                let newestFirst = cache.sorted { $0.value.date > $1.value.date }.prefix(500)
                cache = Dictionary(uniqueKeysWithValues: newestFirst.map { ($0.key, $0.value) })
            }
            persistDiskCache()
        }

        private func dedupOffers(_ offers: [StoreOffer]) -> [StoreOffer] {
            var seen = Set<String>()
            var out: [StoreOffer] = []
            out.reserveCapacity(offers.count)

            for offer in offers {
                let key = "\(offer.store)|\(offer.productURL.absoluteString)"
                if !seen.contains(key) {
                    seen.insert(key)
                    out.append(offer)
                }
            }
            return sortOffersByPrice(out)
        }

        private func sortOffersByPrice(_ offers: [StoreOffer]) -> [StoreOffer] {
            offers.sorted { lhs, rhs in
                switch (lhs.price, rhs.price) {
                case let (l?, r?):
                    if l != r { return l < r }
                    return lhs.store.localizedCaseInsensitiveCompare(rhs.store) == .orderedAscending
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.store.localizedCaseInsensitiveCompare(rhs.store) == .orderedAscending
                }
            }
        }

        private func filterUsableOffers(_ offers: [StoreOffer], query: String, sizeHint: String?) -> [StoreOffer] {
            // First apply basic filters
            let basicFiltered = offers.filter { offer in
                let storeName = offer.store.trimmingCharacters(in: .whitespacesAndNewlines)
                return !storeName.isEmpty && offer.isProbablyMatch && offer.price != nil
            }
            
            // Then apply ProductMatcher ranking and filtering
            return ProductMatcher.rankAndFilter(
                offers: basicFiltered,
                query: query,
                sizeHint: sizeHint
            )
        }

        // MARK: - NZ via Worker

        private struct WorkerResponse: Decodable {
            let source: String?
            let query: String?
            let stores: [WorkerStore]
            let fetchedAt: String?
        }

        private struct WorkerStore: Decodable {
            let chain: String
            let store: String
            let price: Double?
            let regularPrice: Double?
            let salePrice: Double?

            let currency: String?
            let currencyCode: String?

            let name: String?
            let productTitle: String?
            let error: String?

            let lat: Double?
            let lon: Double?
            let storeId: String?
            let branchId: String?

            let image: String?
            let imageUrl: String?
            let imageURL: String?

            let productUrl: String?
            let productURL: String?
            let detailsText: String?

            // Optional promotion passthrough from retailer payloads: an
            // explicit voucher / special description, a member ("club" /
            // "Everyday Rewards") price, or a multi-buy deal. All optional so
            // older worker responses decode unchanged.
            let promoText: String?
            let promotion: String?
            let promo: String?
            let clubPrice: Double?
            let memberPrice: Double?
            let multiBuy: String?

            // Optional identifiers from retailer payloads / worker passthrough.
            let productID: String?
            let ProductId: String?
            let productId: String?
            let id: String?
        }

        /// Session for the price worker, tuned for a phone on cellular: wait
        /// for connectivity instead of failing the moment a cell handover
        /// drops the link, but bound the whole attempt so a dead zone can't
        /// pin a fetch slot for long.
        private static let workerSession: URLSession = {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 25
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            return URLSession(configuration: config)
        }()

        /// Transient failures worth one more go after a short pause.
        private static func isRetryable(_ error: Error) -> Bool {
            guard let urlError = error as? URLError else { return false }
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .internationalRoamingOff, .callIsActive,
                 .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        /// GETs the worker once, retrying a single time on a transient
        /// network error. Throws when both attempts fail so the caller can
        /// tell "no offers" from "couldn't ask".
        private func workerData(for request: URLRequest) async throws -> Data {
            var attempt = 0
            while true {
                do {
                    let (data, response) = try await Self.workerSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200...299).contains(http.statusCode) else {
                        throw URLError(http.statusCode >= 500 ? .badServerResponse : .resourceUnavailable)
                    }
                    return data
                } catch {
                    attempt += 1
                    guard attempt < 2, Self.isRetryable(error), !Task.isCancelled else { throw error }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }

        /// Nil means the request itself failed (offline, timed out, server
        /// error), as opposed to the worker answering with no matches.
        private func fetchOffersFromWorker(
            for cleanQuery: String,
            coordinate: CLLocationCoordinate2D?
        ) async -> [StoreOffer]? {
            guard var comps = URLComponents(string: "\(workerBaseURL)/search") else { return [] }

            var queryItems: [URLQueryItem] = [URLQueryItem(name: "q", value: cleanQuery)]
            if let c = coordinate {
                queryItems.append(URLQueryItem(name: "lat", value: String(c.latitude)))
                queryItems.append(URLQueryItem(name: "lon", value: String(c.longitude)))
            }
            comps.queryItems = queryItems

            guard let url = comps.url else { return [] }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let data = try await workerData(for: req)
                let decoded = try JSONDecoder().decode(WorkerResponse.self, from: data)

                return decoded.stores.compactMap { item in
                    let chain = item.chain.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !chain.isEmpty else { return nil }

                    let productTitle = (item.productTitle ?? item.name)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let productTitle, !productTitle.isEmpty else { return nil }

                    let storeCoordinate: CLLocationCoordinate2D? = {
                        if let lat = item.lat, let lon = item.lon {
                            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        }
                        return nil
                    }()

                    let distanceMeters: Double? = {
                        guard let user = coordinate, let store = storeCoordinate else { return nil }
                        let userLoc = CLLocation(latitude: user.latitude, longitude: user.longitude)
                        let storeLoc = CLLocation(latitude: store.latitude, longitude: store.longitude)
                        return userLoc.distance(from: storeLoc)
                    }()

                    if let d = distanceMeters, d > (StockAvailability.searchRadiusKm * 1000) {
                        return nil
                    }

                    // Retailer search page for this chain. Built with URLComponents
                    // so any query text (odd spaces, '#', '&') is encoded rather than
                    // producing an unparseable URL.
                    let fallbackURL: URL? = {
                        let lower = chain.lowercased()
                        let host: String?
                        if lower.contains("woolworth") {
                            host = "www.woolworths.co.nz"
                        } else if lower.contains("pak") && lower.contains("save") {
                            host = "www.paknsave.co.nz"
                        } else if lower.contains("new world") {
                            host = "www.newworld.co.nz"
                        } else {
                            host = nil
                        }

                        guard let host else { return URL(string: workerBaseURL) }
                        var comps = URLComponents()
                        comps.scheme = "https"
                        comps.host = host
                        comps.path = "/shop/searchproducts"
                        comps.queryItems = [URLQueryItem(name: "search", value: cleanQuery)]
                        return comps.url
                    }()

                    let resolvedCurrency = (item.currencyCode ?? item.currency ?? "NZD")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let resolvedProductURL = URL(string: item.productURL ?? item.productUrl ?? "") ?? fallbackURL else {
                        return nil
                    }
                    let resolvedImageURL = self.resolveRetailerImageURL(
                        chain: chain,
                        workerImage: item.imageURL ?? item.imageUrl ?? item.image,
                        productURL: item.productURL ?? item.productUrl,
                        productID: item.productID ?? item.ProductId ?? item.productId ?? item.id
                    )

                    let bestPrice = item.price ?? item.salePrice ?? item.regularPrice
                    guard let bestPrice else { return nil }

                    let promoText: String? = {
                        let f = NumberFormatter()
                        f.numberStyle = .currency
                        f.currencyCode = resolvedCurrency
                        func money(_ v: Double) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }

                        // 1. Explicit voucher / promotion text from the retailer wins.
                        let explicit = [item.promoText, item.promotion, item.promo, item.multiBuy]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .first { !$0.isEmpty }
                        if let explicit { return explicit }

                        // 2. Sale price below the regular price.
                        if let sale = item.salePrice,
                           let regular = item.regularPrice,
                           sale < regular {
                            return "Special \(money(sale)) (was \(money(regular)))"
                        }

                        // 3. Member / club price below the shelf price.
                        if let club = item.clubPrice ?? item.memberPrice,
                           club < bestPrice {
                            return "Member price \(money(club)) (shelf \(money(bestPrice)))"
                        }
                        return nil
                    }()

                    // Improved isProbablyMatch: check error AND token overlap using cleanQuery
                    let isProbablyMatch: Bool = {
                        guard item.error == nil else { return false }
                        
                        let normalizedQuery = StockAvailability.normalize(cleanQuery)
                        let normalizedTitle = productTitle.lowercased()
                        
                        let queryTokens = normalizedQuery.split(separator: " ").map { String($0) }
                        guard !queryTokens.isEmpty else { return false }
                        
                        // Product title must contain at least one query token
                        return queryTokens.contains { token in
                            normalizedTitle.contains(token)
                        }
                    }()
                    
                    let offer = StoreOffer(
                        store: chain,
                        productURL: resolvedProductURL,
                        currencyCode: resolvedCurrency,
                        price: bestPrice,
                        promoText: promoText,
                        isProbablyMatch: isProbablyMatch,
                        storeCoordinate: storeCoordinate,
                        distanceMeters: distanceMeters,
                        productTitle: productTitle,
                        imageURL: resolvedImageURL,
                        detailsText: item.detailsText
                    )

                    if let d = offer.distanceMeters, d <= 800 {
                        let key = "\(chain)|\(item.store)"
                        if !self.proximityNotifiedKeys.contains(key) {
                            self.proximityNotifiedKeys.insert(key)
                            StockAvailability.triggerProximity(offer)
                        }
                    }

                    return offer
                }
            } catch {
                print("[StockAvailability] Worker lookup failed for \"\(cleanQuery)\": \(error.localizedDescription)")
                return nil
            }
        }


        private func resolveRetailerImageURL(
            chain: String,
            workerImage: String?,
            productURL: String?,
            productID: String?
        ) -> URL? {
            if let workerImage,
               let directURL = URL(string: workerImage),
               directURL.scheme != nil {
                return directURL
            }

            let lower = chain.lowercased()
            let isFoodstuffs = lower.contains("new world") || (lower.contains("pak") && lower.contains("save"))

            guard isFoodstuffs else { return nil }

            let resolvedID = normalizedRetailProductID(productID)
                ?? normalizedRetailProductID(extractRetailProductID(from: productURL))

            guard let resolvedID else { return nil }
            return URL(string: "https://a.fsimg.co.nz/product/retail/fan/image/400x400/\(resolvedID).png")
        }

        private func extractRetailProductID(from productURL: String?) -> String? {
            guard let productURL,
                  let url = URL(string: productURL) else { return nil }

            let components = url.pathComponents.filter { $0 != "/" }
            guard let productIndex = components.lastIndex(of: "product"),
                  productIndex + 1 < components.count else {
                return nil
            }

            return components[productIndex + 1]
        }

        private func normalizedRetailProductID(_ raw: String?) -> String? {
            guard let raw else { return nil }

            let trimmed = raw
                .removingPercentEncoding ?? raw

            let cleaned = trimmed
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "")

            return cleaned.isEmpty ? nil : cleaned
        }

        // MARK: - UK fallback

        private func performUKLookup(normalizedQuery: String) async -> [StoreOffer] {
            guard !normalizedQuery.isEmpty else { return [] }

            let offers: [StoreOffer] = await withTaskGroup(of: StoreOffer?.self) { group in
                for ep in ukEndpoints {
                    group.addTask {
                        guard let url = ep.buildURL(normalizedQuery) else { return nil }

                        switch ep.strategy {
                        case .htmlScrape(let positiveHints, let negativeHints, let allowJSRender):
                            let html = await StockAvailability.fetchHTML(url)
                            let htmlLower = html?.lowercased() ?? ""

                            if !htmlLower.isEmpty,
                               negativeHints.contains(where: { htmlLower.contains($0) }) {
                                return StoreOffer(
                                    store: ep.store,
                                    productURL: url,
                                    currencyCode: ep.currencyCode,
                                    price: nil,
                                    promoText: nil,
                                    isProbablyMatch: false,
                                    storeCoordinate: nil,
                                    distanceMeters: nil,
                                    productTitle: nil,
                                    imageURL: nil,
                                    detailsText: nil
                                )
                            }

                            let parsed = StockAvailability.parseOfferSignals(
                                store: ep.store,
                                currencyCode: ep.currencyCode,
                                url: url,
                                html: html,
                                normalizedQuery: normalizedQuery,
                                positiveHints: positiveHints
                            )

                            if (parsed == nil || parsed?.isProbablyMatch == false), allowJSRender {
                                let renderer = await JSRenderer()
                                if let rendered = await renderer.fetchRenderedHTML(url: url) {
                                    if let parsedRendered = StockAvailability.parseOfferSignals(
                                        store: ep.store,
                                        currencyCode: ep.currencyCode,
                                        url: url,
                                        html: rendered,
                                        normalizedQuery: normalizedQuery,
                                        positiveHints: positiveHints
                                    ) {
                                        return parsedRendered
                                    }
                                }
                            }

                            return parsed
                        }
                    }
                }

                var out: [StoreOffer] = []
                for await item in group {
                    if let item { out.append(item) }
                }
                return out
            }

            let filtered = filterUsableOffers(offers, query: normalizedQuery, sizeHint: nil)
            return sortOffersByPrice(filtered)
        }
    }
}

// MARK: - HTML parsing (UK)

extension StockAvailability {

    static func parseOfferSignals(
        store: String,
        currencyCode: String,
        url: URL,
        html: String?,
        normalizedQuery: String,
        positiveHints: [String]
    ) -> StoreOffer? {
        guard let html, !html.isEmpty else { return nil }

        let h = html.lowercased()
        let tokens = tokensForMatch(normalizedQuery)
        let tokenHitCount = tokens.filter { h.contains($0) }.count
        let hintHit = positiveHints.contains(where: { h.contains($0) })
        let isProbablyMatch = (tokenHitCount >= 1 && hintHit) || tokenHitCount >= 3

        let price = extractJSONLDPrice(from: html) ?? extractFirstPrice(from: html, currencyCode: currencyCode)
        let promo = extractJSONLDPromoText(from: html) ?? extractPromoText(from: html)

        return StoreOffer(
            store: store,
            productURL: url,
            currencyCode: currencyCode,
            price: price,
            promoText: promo,
            isProbablyMatch: isProbablyMatch,
            storeCoordinate: nil,
            distanceMeters: nil,
            productTitle: nil,
            imageURL: nil,
            detailsText: nil
        )
    }

    static func extractJSONLDPrice(from html: String) -> Double? {
        let pattern = "\\\"(?:price|lowPrice)\\\"\\s*:\\s*(?:\\\"([0-9]+(?:\\.[0-9]{1,2})?)\\\"|([0-9]+(?:\\.[0-9]{1,2})?))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = re.firstMatch(in: html, options: [], range: range) else { return nil }

        for idx in [1, 2] {
            if match.numberOfRanges > idx, let r = Range(match.range(at: idx), in: html) {
                if let v = Double(String(html[r])) { return v }
            }
        }
        return nil
    }

    static func extractJSONLDPromoText(from html: String) -> String? {
        let candidates = extractSnippets(
            from: html,
            patterns: ["\\\"(?:description|name)\\\"\\s*:\\s*\\\"([^\\\"]{6,80})\\\""],
            max: 6
        )
        return candidates.first(where: { looksLikePromo($0) })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFirstPrice(from html: String, currencyCode: String) -> Double? {
        let pattern: String
        switch currencyCode.uppercased() {
        case "GBP":
            pattern = "(?:£|GBP\\s*)\\s*([0-9]+(?:\\.[0-9]{1,2})?)"
        case "NZD":
            pattern = "(?:NZ\\$|\\$(?=[0-9]))\\s*([0-9]+(?:\\.[0-9]{1,2})?)"
        default:
            pattern = "([0-9]+(?:\\.[0-9]{1,2})?)"
        }

        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = re.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let r1 = Range(match.range(at: 1), in: html) else { return nil }

        return Double(String(html[r1]))
    }

    static func extractPromoText(from html: String) -> String? {
        let keywords = [
            "clubcard", "nectar", "offer", "save", "discount", "was", "now", "price drop",
            "multi-buy", "multibuy", "deal", "% off", "half price", "2 for", "3 for",
            "special", "everyday low"
        ]

        let lower = html.lowercased()
        guard let hit = keywords.first(where: { lower.contains($0) }),
              let range = lower.range(of: hit) else { return nil }

        let start = lower.index(range.lowerBound, offsetBy: -80, limitedBy: lower.startIndex) ?? lower.startIndex
        let end = lower.index(range.upperBound, offsetBy: 120, limitedBy: lower.endIndex) ?? lower.endIndex

        let snippet = String(html[start..<end])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return snippet.count >= 8 ? String(snippet.prefix(120)) : nil
    }

    static func looksLikePromo(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("save")
            || l.contains("offer")
            || l.contains("discount")
            || l.contains("clubcard")
            || l.contains("nectar")
            || l.contains("special")
            || l.contains("%")
            || (l.contains("was") && l.contains("now"))
    }

    static func extractSnippets(from html: String, patterns: [String], max: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(max)

        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)

            for m in re.matches(in: html, options: [], range: range).prefix(max) {
                guard m.numberOfRanges >= 2, let r1 = Range(m.range(at: 1), in: html) else { continue }
                out.append(String(html[r1]))
                if out.count >= max { return out }
            }
        }

        return out
    }
}

// MARK: - Networking

extension StockAvailability {

    static func fetchData(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func fetchHTML(_ url: URL) async -> String? {
        guard let data = await fetchData(url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - JS renderer

@MainActor
final class JSRenderer: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasFinished = false

    override init() {
        super.init()
    }

    func fetchRenderedHTML(url: URL) async -> String? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
        self.hasFinished = false

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 16_000_000_000)
                self?.finish(nil)
            }
            wv.load(req)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)

            do {
                let result = try await webView.evaluateJavaScript("document.documentElement.outerHTML.toString()")
                self.finish(result as? String)
            } catch {
                self.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ html: String?) {
        guard !hasFinished else { return }
        hasFinished = true

        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: html)
        continuation = nil
        webView = nil
    }
}

// MARK: - DDG fallback

extension StockAvailability {

    static func fallbackDuckDuckGoLiteMatch(normalizedQuery: String, country: RetailCountry) async -> URL? {
        let retailerTerms = country == .gb
            ? "tesco sainsburys waitrose marksandspencer asda morrisons iceland"
            : "woolworths paknsave newworld"

        let combined = "\(normalizedQuery) \(retailerTerms)"
        guard let encoded = combined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let ddgURL = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)"),
              let html = await fetchHTML(ddgURL) else { return nil }

        let h = html.lowercased()
        let domainHit = country == .gb
            ? (h.contains("tesco.com") || h.contains("sainsburys.co.uk") || h.contains("waitrose.com") || h.contains("marksandspencer.com") || h.contains("asda.com") || h.contains("morrisons.com") || h.contains("iceland.co.uk"))
            : (h.contains("woolworths.co.nz") || h.contains("paknsave.co.nz") || h.contains("newworld.co.nz"))

        guard domainHit else { return nil }
        return tokensForMatch(normalizedQuery).contains(where: { h.contains($0) }) ? ddgURL : nil
    }
}

// MARK: - Matching helpers

extension StockAvailability {

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : Character(" ") }
            .reduce("") { $0 + String($1) }
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokensForMatch(_ normalizedQuery: String) -> [String] {
        normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .prefix(6)
            .map { $0 }
    }
}

extension StockAvailability {
    static func triggerProximity(_ offer: StoreOffer) {
        guard let handler = onProximityStoreDetected else { return }
        DispatchQueue.main.async {
            handler(offer)
        }
    }
    
    // MARK: - Ingredient Product Preferences
    
    /// Saves a user-selected product preference for an ingredient.
    /// Call this when the user explicitly chooses a product (e.g., via long-press or swipe action).
    static func userSelectedOffer(_ offer: StoreOffer, forIngredient ingredient: String) async {
        await IngredientProductCache.shared.save(offer: offer, for: ingredient)
    }
    
    /// Resets the product preference for a specific ingredient.
    static func resetProductPreference(forIngredient ingredient: String) async {
        await IngredientProductCache.shared.clear(for: ingredient)
    }
    
    /// Gets the cached product preference for an ingredient, if one exists.
    static func preferredProduct(forIngredient ingredient: String) async -> StoreOffer? {
        guard let cached = await IngredientProductCache.shared.preferred(for: ingredient) else {
            return nil
        }
        return cached.toStoreOffer()
    }
}

