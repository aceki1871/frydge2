//
//  ApplePaymentHandler.swift
//  FrydgeRecipes
//

import Foundation
import PassKit

/// Handles Apple Pay payment processing via the Frydge Cloudflare Worker backend.
///
/// Flow:
///   1. `startPayment(for:quantity:sellerAccountId:completion:)`
///      → POST /stripe/connect/create-intent (if sellerAccountId set)
///        or POST /stripe/create-payment-intent (direct charge)
///      → stores paymentIntentId, then presents Apple Pay sheet
///   2. User authorises → `didAuthorizePayment` fires
///      → POST /stripe/confirm-apple-pay with raw Apple Pay token data
///   3. Backend converts token → Stripe PaymentMethod → confirms intent
///   4. Result propagated back to caller via completion handler
///
@MainActor
class ApplePaymentHandler: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var paymentStatus: PaymentStatus = .idle
    @Published var errorMessage: String?

    enum PaymentStatus {
        case idle
        case preparingIntent   // creating PaymentIntent on backend
        case awaitingUser      // Apple Pay sheet is visible
        case processing        // confirming with backend
        case success
        case failed
    }

    // MARK: - Private

    /// Both were hardcoded copies. Reading StripeConfig keeps them in step with
    /// the rest of the app and with the entitlement.
    private var backendBaseURL: String { StripeConfig.backendBaseURL }
    private var merchantIdentifier: String { StripeConfig.merchantIdentifier }

    private let supportedNetworks: [PKPaymentNetwork] = [
        .visa, .masterCard, .amex, .discover, .chinaUnionPay, .interac,
    ]

    private var paymentCompletion: ((Bool) -> Void)?
    private var currentPaymentIntentId: String?
    private var currentSellerAccountId: String?

    // Keep a strong reference to the controller while the sheet is visible
    private var activeController: PKPaymentAuthorizationController?

    // MARK: - Public

    var canMakePayments: Bool {
        PKPaymentAuthorizationController.canMakePayments(usingNetworks: supportedNetworks)
    }

    /// Start an Apple Pay payment for a marketplace listing.
    ///
    /// - Parameters:
    ///   - product: The `VendorProduct` being purchased.
    ///   - quantity: How many units.
    ///   - sellerAccountId: The seller's Stripe Connect `acct_...` ID. When set the
    ///     payment is routed via Connect; otherwise a direct charge is created.
    ///   - presetPaymentIntentId: A PaymentIntent that was already created
    ///     server-side (e.g. by `MarketplaceOrderService.createOrder`). When set,
    ///     no new intent is created — the sheet confirms this one, so the payment
    ///     stays attached to its order record.
    ///   - completion: Called with `true` on success, `false` on failure or cancellation.
    func startPayment(
        for product: VendorProduct,
        quantity: Int = 1,
        sellerAccountId: String? = nil,
        presetPaymentIntentId: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard canMakePayments else {
            errorMessage = "Apple Pay is not available on this device."
            paymentStatus = .failed
            completion(false)
            return
        }

        paymentCompletion = completion
        currentSellerAccountId = sellerAccountId
        paymentStatus = .preparingIntent

        if let presetPaymentIntentId {
            currentPaymentIntentId = presetPaymentIntentId
            paymentStatus = .awaitingUser
            presentApplePay(for: product, quantity: quantity)
            return
        }

        let amountCents = (NSDecimalNumber(decimal: product.price * Decimal(quantity)) as Decimal * 100)
        let cents = Int(truncating: NSDecimalNumber(decimal: amountCents))

        Task {
            do {
                let intentId = try await createPaymentIntent(
                    amountCents: cents,
                    currency: product.currency,
                    sellerAccountId: sellerAccountId,
                    metadata: [
                        "product_id": product.id,
                        "product_name": product.name,
                        "seller_id": product.vendorID,
                    ]
                )
                currentPaymentIntentId = intentId
                paymentStatus = .awaitingUser
                presentApplePay(for: product, quantity: quantity)
            } catch {
                // Surface the real reason the Apple Pay sheet never appeared —
                // the sheet is only presented after the PaymentIntent is created,
                // so a failure here looks like "nothing happens".
                print("[ApplePay] PaymentIntent creation failed: \(error)")
                errorMessage = error.localizedDescription
                paymentStatus = .failed
                paymentCompletion?(false)
                paymentCompletion = nil
            }
        }
    }

    // MARK: - Private: Backend calls

    private func createPaymentIntent(
        amountCents: Int,
        currency: String,
        sellerAccountId: String?,
        metadata: [String: String] = [:]
    ) async throws -> String {
        let endpoint: String
        var body: [String: Any] = [
            "amount": amountCents,
            "currency": currency,
            "metadata": metadata,
        ]

        if let sellerId = sellerAccountId {
            endpoint = "\(backendBaseURL)/connect/create-intent"
            body["sellerAccountId"] = sellerId
            // Marketplace platform fee retained by Frydge (see MarketplaceFees)
            body["applicationFeeAmount"] = MarketplaceFees.fee(forCents: amountCents)
        } else {
            endpoint = "\(backendBaseURL)/create-payment-intent"
        }

        guard let url = URL(string: endpoint) else { throw PaymentBackendError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let detail: String = {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = json["error"] as? String { return msg }
                return bodyText.isEmpty ? "(empty body)" : bodyText
            }()
            throw PaymentBackendError.serverError("HTTP \(status) from \(endpoint): \(detail)")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Accept the documented shape { paymentIntentId, clientSecret }, but also
        // tolerate alternate shapes from an older/different deployed worker:
        //   • a bare `id`
        //   • deriving the id from the client secret (pi_XXX_secret_YYY → pi_XXX)
        if let intentId = (json?["paymentIntentId"] as? String) ?? (json?["id"] as? String) {
            return intentId
        }
        if let secret = (json?["clientSecret"] as? String) ?? (json?["client_secret"] as? String),
           let id = secret.components(separatedBy: "_secret_").first,
           id.hasPrefix("pi_") {
            return id
        }

        // Still nothing usable — surface the raw body so the actual shape is visible.
        let raw = String(data: data, encoding: .utf8) ?? "(non-text body)"
        print("[ApplePay] Unexpected create-intent response from \(endpoint): \(raw)")
        throw PaymentBackendError.serverError("No paymentIntentId in response from \(endpoint). Body: \(raw)")
    }

    private func confirmApplePay(
        intentId: String,
        paymentData: String,
        transactionIdentifier: String,
        paymentNetwork: String,
        sellerAccountId: String?
    ) async throws {
        guard let url = URL(string: "\(backendBaseURL)/confirm-apple-pay") else {
            throw PaymentBackendError.badURL
        }
        var body: [String: Any] = [
            "paymentIntentId": intentId,
            "paymentData": paymentData,
            "transactionIdentifier": transactionIdentifier,
            "paymentNetwork": paymentNetwork,
        ]
        if let sellerId = sellerAccountId {
            body["sellerAccountId"] = sellerId
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw PaymentBackendError.serverError(json?["error"] as? String ?? "Payment confirmation failed")
        }
    }

    // MARK: - Private: Apple Pay sheet

    private func presentApplePay(for product: VendorProduct, quantity: Int) {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantIdentifier
        request.countryCode = countryCode(for: product.currency)
        request.currencyCode = product.currency
        request.supportedNetworks = supportedNetworks
        request.merchantCapabilities = [.threeDSecure, .debit, .credit]

        let itemPrice = NSDecimalNumber(decimal: product.price * Decimal(quantity))
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(label: "\(product.name) × \(quantity)", amount: itemPrice),
            PKPaymentSummaryItem(label: "Frydge Marketplace", amount: itemPrice, type: .final),
        ]

        let controller = PKPaymentAuthorizationController(paymentRequest: request)
        controller.delegate = self
        activeController = controller

        controller.present { [weak self] presented in
            if !presented {
                Task { @MainActor in
                    self?.errorMessage = "Could not present Apple Pay."
                    self?.paymentStatus = .failed
                    self?.paymentCompletion?(false)
                    self?.paymentCompletion = nil
                    self?.activeController = nil
                }
            }
        }
    }

    private func countryCode(for currency: String) -> String {
        switch currency.uppercased() {
        case "NZD": return "NZ"
        case "GBP": return "GB"
        case "AUD": return "AU"
        case "EUR": return "IE"
        case "CAD": return "CA"
        default:    return "US"
        }
    }
}

// MARK: - PKPaymentAuthorizationControllerDelegate

extension ApplePaymentHandler: PKPaymentAuthorizationControllerDelegate {

    nonisolated func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss()
        Task { @MainActor in
            activeController = nil
            // Only fail here if we never got a successful confirmation
            if case .awaitingUser = paymentStatus {
                paymentStatus = .failed
                paymentCompletion?(false)
                paymentCompletion = nil
            }
        }
    }

    nonisolated func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        Task { @MainActor in
            guard let intentId = currentPaymentIntentId else {
                completion(PKPaymentAuthorizationResult(status: .failure, errors: [PKPaymentError(.unknownError)]))
                paymentStatus = .failed
                paymentCompletion?(false)
                paymentCompletion = nil
                return
            }

            paymentStatus = .processing

            let paymentData = payment.token.paymentData.base64EncodedString()
            let transactionId = payment.token.transactionIdentifier
            let network = payment.token.paymentMethod.network?.rawValue ?? ""

            do {
                try await confirmApplePay(
                    intentId: intentId,
                    paymentData: paymentData,
                    transactionIdentifier: transactionId,
                    paymentNetwork: network,
                    sellerAccountId: currentSellerAccountId
                )
                paymentStatus = .success
                completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
                paymentCompletion?(true)
            } catch {
                errorMessage = error.localizedDescription
                paymentStatus = .failed
                completion(PKPaymentAuthorizationResult(status: .failure, errors: [PKPaymentError(.unknownError)]))
                paymentCompletion?(false)
            }
            paymentCompletion = nil
        }
    }
}

// MARK: - Errors

enum PaymentBackendError: LocalizedError {
    case badURL
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .badURL:              return "Invalid backend URL."
        case .serverError(let m): return m
        }
    }
}
