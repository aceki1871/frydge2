//
//  MarketplaceOrderService.swift
//  FrydgeRecipes
//
//  Durable order records for the marketplace.
//
//  THE PROBLEM THIS SOLVES
//  -----------------------
//  Before this, `MarketplaceCheckoutView` took a payment and called `dismiss()`.
//  Nothing persisted. Neither buyer nor seller had any record that a transaction
//  had happened, so there was no way to fulfil, dispute or refund an order.
//
//  WHERE ORDERS LIVE
//  -----------------
//  Cloudflare D1, behind the frydge-api worker's `/marketplace/*` routes. Not CloudKit:
//
//    * an order has TWO parties, so neither user's private database works
//    * the public database would make every order readable by every user
//    * it must be authoritative — a client claiming "I paid" is not evidence.
//      Stripe's webhook writes the paid status server-side; the app cannot.
//
//  LIFECYCLE
//  ---------
//      pendingPayment ──webhook──► paid ──seller──► ready ──buyer──► received
//                     └─webhook──► paymentFailed
//      any ──webhook──► refunded | disputed
//

import Foundation
import os

// MARK: - Platform fee

/// The marketplace's platform cut, in basis points.
///
/// Deliberately much smaller than the clerk/store system's cut: the P2P
/// marketplace exists for small vendors and start-ups, so the barrier to
/// selling stays low. Change the fee here and every marketplace payment path
/// (card, Apple Pay, Tap to Pay) follows.
enum MarketplaceFees {
    /// 200 bps = 2%.
    static let feeBps = 200

    /// Fee in the smallest currency unit. Minimum 1 so Stripe accepts it —
    /// a zero application fee on a Connect charge is rejected.
    static func fee(forCents cents: Int) -> Int {
        max(1, Int((Double(cents) * Double(feeBps) / 10_000.0).rounded()))
    }
}

// MARK: - Model

struct MarketplaceOrder: Identifiable, Codable, Hashable {

    enum Status: String, Codable {
        case pendingPayment = "pending_payment"
        case paid
        case ready
        case received
        case cancelled
        case paymentFailed = "payment_failed"
        case refunded
        case disputed

        var isTerminal: Bool {
            switch self {
            case .received, .cancelled, .refunded, .disputed: return true
            default: return false
            }
        }

        var displayName: String {
            switch self {
            case .pendingPayment: return "Awaiting payment"
            case .paid:           return "Paid"
            case .ready:          return "Ready for collection"
            case .received:       return "Completed"
            case .cancelled:      return "Cancelled"
            case .paymentFailed:  return "Payment failed"
            case .refunded:       return "Refunded"
            case .disputed:       return "Disputed"
            }
        }
    }

    let id: String
    let paymentIntentId: String?
    let listingId: String?
    let listingTitle: String?
    let quantity: Int
    let buyerUserId: String
    let sellerUserId: String?
    let sellerAccountId: String?

    /// Smallest currency unit (cents). Never a Double — floating point and money
    /// do not mix.
    let amount: Int
    let currency: String
    let platformFee: Int

    let status: Status
    let stripeStatus: String?
    let sellerMarkedReadyAt: Date?
    let buyerConfirmedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        return formatter.string(from: NSNumber(value: Double(amount) / 100.0))
            ?? "\(currency.uppercased()) \(String(format: "%.2f", Double(amount) / 100.0))"
    }

    /// Seller can only mark ready once the money has actually landed.
    var canMarkReady: Bool { status == .paid }

    /// Buyers often receive goods before the seller taps anything, so allow
    /// confirmation from `paid` as well as `ready`.
    var canConfirmReceipt: Bool { status == .paid || status == .ready }

    private enum CodingKeys: String, CodingKey {
        case id, paymentIntentId, listingId, listingTitle, quantity
        case buyerUserId, sellerUserId, sellerAccountId
        case amount, currency, platformFee
        case status, stripeStatus
        case sellerMarkedReadyAt, buyerConfirmedAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        paymentIntentId = try c.decodeIfPresent(String.self, forKey: .paymentIntentId)
        listingId = try c.decodeIfPresent(String.self, forKey: .listingId)
        listingTitle = try c.decodeIfPresent(String.self, forKey: .listingTitle)
        quantity = (try? c.decode(Int.self, forKey: .quantity)) ?? 1
        buyerUserId = try c.decode(String.self, forKey: .buyerUserId)
        sellerUserId = try c.decodeIfPresent(String.self, forKey: .sellerUserId)
        sellerAccountId = try c.decodeIfPresent(String.self, forKey: .sellerAccountId)
        amount = try c.decode(Int.self, forKey: .amount)
        currency = try c.decode(String.self, forKey: .currency)
        platformFee = (try? c.decode(Int.self, forKey: .platformFee)) ?? 0

        let rawStatus = (try? c.decode(String.self, forKey: .status)) ?? "pending_payment"
        status = Status(rawValue: rawStatus) ?? .pendingPayment
        stripeStatus = try c.decodeIfPresent(String.self, forKey: .stripeStatus)

        // The worker stores unix seconds.
        func date(_ key: CodingKeys) -> Date? {
            guard let secs = try? c.decodeIfPresent(Double.self, forKey: key) else { return nil }
            return Date(timeIntervalSince1970: secs)
        }
        sellerMarkedReadyAt = date(.sellerMarkedReadyAt)
        buyerConfirmedAt = date(.buyerConfirmedAt)
        createdAt = date(.createdAt) ?? Date()
        updatedAt = date(.updatedAt) ?? Date()
    }
}

// MARK: - Service

@MainActor
final class MarketplaceOrderService: ObservableObject {

    static let shared = MarketplaceOrderService()

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "MarketplaceOrders")

    @Published private(set) var buyerOrders: [MarketplaceOrder] = []
    @Published private(set) var sellerOrders: [MarketplaceOrder] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    /// iCloud account switched while installed: the cached orders belong to
    /// the previous buyer/seller identity. Requests re-read `appleUserID` from
    /// UserDefaults, so clearing the cache is enough for the next fetch to
    /// run as the new account.
    func clearForAccountChange() {
        buyerOrders = []
        sellerOrders = []
        lastError = nil
    }

    private let baseURL = "\(FrydgeBackend.host)/marketplace"

    private init() {}

    // MARK: Identity

    /// The CloudKit user record name, already resolved and cached by
    /// FrydgeManager. Orders are keyed on this.
    private var currentUserId: String? {
        let id = UserDefaults.standard.string(forKey: "appleUserID")
        return (id?.isEmpty == false) ? id : nil
    }

    // MARK: Create

    /// Creates the order and its Stripe PaymentIntent in one call, so an order
    /// can never exist without an intent or vice versa.
    ///
    /// The seller's Stripe account is resolved server-side — from `venueId` for
    /// store purchases, or from `sellerUserId` for P2P listings (registered at
    /// Connect onboarding). A client-supplied account ID is no longer trusted,
    /// so none is sent.
    ///
    /// - Parameters:
    ///   - attemptId: a checkout-attempt identifier the caller generates once per
    ///     checkout and reuses across every retry of that checkout. The server
    ///     reserves the order under it and derives the Stripe idempotency key
    ///     from the reserved order, so a retried or duplicated request returns
    ///     the same order and PaymentIntent instead of minting a second charge.
    /// - Returns: the order ID and the client secret to drive payment with.
    func createOrder(
        attemptId: String,
        amount: Int,
        currency: String,
        sellerUserId: String?,
        venueId: String? = nil,
        listingId: String?,
        listingTitle: String?,
        quantity: Int = 1,
        applicationFeeAmount: Int? = nil
    ) async throws -> (orderId: String, paymentIntentId: String, clientSecret: String) {

        guard let buyerUserId = currentUserId else {
            throw OrderError.notSignedIn
        }

        var body: [String: Any] = [
            "attemptId": attemptId,
            "buyerUserId": buyerUserId,
            "amount": amount,
            "currency": currency.lowercased(),
            "quantity": quantity,
        ]
        body["sellerUserId"] = sellerUserId
        body["venueId"] = venueId
        body["listingId"] = listingId
        body["listingTitle"] = listingTitle
        if let applicationFeeAmount { body["applicationFeeAmount"] = applicationFeeAmount }

        let json = try await post("/orders/create", body: body)

        guard let orderId = json["orderId"] as? String,
              let paymentIntentId = json["paymentIntentId"] as? String,
              let clientSecret = json["clientSecret"] as? String else {
            throw OrderError.malformedResponse(String(describing: json))
        }

        Self.log.notice("Created order \(orderId) for \(amount) \(currency)")
        return (orderId, paymentIntentId, clientSecret)
    }

    // MARK: In-person collection (Tap to Pay)

    struct TerminalOrder {
        let orderId: String
        let paymentIntentId: String
        let clientSecret: String
    }

    /// Creates an order whose PaymentIntent is collected in person via Stripe
    /// Terminal — the seller's iPhone acts as the card reader. Walk-up buyers
    /// usually don't have the app, so the seller drives this flow and no buyer
    /// identity is required.
    ///
    /// The seller's Connect account is resolved server-side from `sellerUserId`
    /// just like the card flow; the marketplace fee is applied there.
    func createInPersonOrder(
        attemptId: String,
        amount: Int,
        currency: String,
        listingId: String?,
        listingTitle: String?
    ) async throws -> TerminalOrder {
        guard let sellerUserId = currentUserId else {
            throw OrderError.notSignedIn
        }

        var body: [String: Any] = [
            "attemptId": attemptId,
            "sellerUserId": sellerUserId,
            "buyerUserId": "in-person",
            "amount": amount,
            "currency": currency.lowercased(),
            "applicationFeeAmount": MarketplaceFees.fee(forCents: amount),
        ]
        body["listingId"] = listingId
        body["listingTitle"] = listingTitle

        let json = try await post("/terminal/orders/create", body: body)

        guard let orderId = json["orderId"] as? String,
              let paymentIntentId = json["paymentIntentId"] as? String,
              let clientSecret = json["clientSecret"] as? String else {
            throw OrderError.malformedResponse(String(describing: json))
        }

        Self.log.notice("Created in-person order \(orderId) for \(amount) \(currency)")
        return TerminalOrder(orderId: orderId, paymentIntentId: paymentIntentId, clientSecret: clientSecret)
    }

    /// Stripe Terminal connection token for marketplace sellers.
    ///
    /// The clerk system mints per-store tokens behind a clerk JWT; marketplace
    /// sellers instead get a platform-account token from the relay-key-guarded
    /// worker, so any signed-in seller can collect without store credentials.
    /// The response may carry the platform's Terminal location (`tml_…`) to
    /// register the Tap to Pay reader under.
    func fetchTerminalConnectionToken() async throws -> (secret: String, locationId: String?) {
        let json = try await post("/terminal/connection-token", body: [:])
        guard let secret = json["secret"] as? String else {
            throw OrderError.malformedResponse(String(describing: json))
        }
        let locationId = (json["locationId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (secret, locationId)
    }

    // MARK: Read

    func refreshOrders(role: Role) async {
        guard let userId = currentUserId else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let json = try await post("/orders/list", body: ["userId": userId, "role": role.rawValue])
            guard let raw = json["orders"] else { return }

            let data = try JSONSerialization.data(withJSONObject: raw)
            let orders = try JSONDecoder().decode([MarketplaceOrder].self, from: data)

            switch role {
            case .buyer:  buyerOrders = orders
            case .seller: sellerOrders = orders
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Self.log.error("Order refresh failed: \(String(describing: error))")
        }
    }

    func fetchOrder(id: String) async throws -> MarketplaceOrder {
        let json = try await post("/orders/get", body: ["orderId": id])
        guard let raw = json["order"] else { throw OrderError.notFound }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(MarketplaceOrder.self, from: data)
    }

    // MARK: Fulfilment

    /// Seller: goods are ready / handed over.
    func markReady(orderId: String) async throws {
        guard let sellerUserId = currentUserId else { throw OrderError.notSignedIn }
        _ = try await post("/orders/mark-ready", body: [
            "orderId": orderId,
            "sellerUserId": sellerUserId,
        ])
        await refreshOrders(role: .seller)
    }

    /// Buyer: goods received. Terminal happy state.
    func confirmReceived(orderId: String) async throws {
        guard let buyerUserId = currentUserId else { throw OrderError.notSignedIn }
        _ = try await post("/orders/confirm-received", body: [
            "orderId": orderId,
            "buyerUserId": buyerUserId,
        ])
        await refreshOrders(role: .buyer)
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else {
            throw OrderError.badURL(baseURL + path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&request)
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body.compactMapValues { $0 }
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(code) else {
            throw OrderError.server(code, json["error"] as? String ?? "Unknown error")
        }
        return json
    }

    enum Role: String {
        case buyer, seller
    }

    enum OrderError: LocalizedError {
        case notSignedIn
        case notFound
        case badURL(String)
        case malformedResponse(String)
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to iCloud to buy or sell in the marketplace."
            case .notFound:
                return "That order could not be found."
            case .badURL(let u):
                return "Invalid marketplace URL: \(u)"
            case .malformedResponse(let body):
                return "Unexpected response from the order server: \(body)"
            case .server(let code, let message):
                return "Order server error (\(code)): \(message)"
            }
        }
    }
}
