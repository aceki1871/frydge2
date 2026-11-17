import Foundation
import SwiftUI

#if canImport(StripePaymentSheet)
import StripePaymentSheet
#endif

// MARK: - Configuration
// Note: StripeConfig and PaymentIntentResponse are defined in StripeConfig.swift

// MARK: - Payment Service

@MainActor
final class StripePaymentService: ObservableObject {
    static let shared = StripePaymentService()

    @Published var isProcessing = false
    @Published var paymentStatus: PaymentStatus = .idle

    enum PaymentStatus: Equatable {
        case idle
        case preparing
        case ready
        case completed
        case failed(String)
        case cancelled
    }

    #if canImport(StripePaymentSheet)
    private var paymentSheet: PaymentSheet?
    #endif

    private init() {
        #if canImport(StripePaymentSheet)
        if StripeConfig.isConfigured {
            StripeAPI.defaultPublishableKey = StripeConfig.publishableKey
        }
        #endif
    }

    // MARK: - Create Payment Intent via Backend

    func preparePayment(
        amount: Decimal,
        currency: String,
        listingID: String,
        sellerName: String,
        productName: String
    ) async throws {
        #if canImport(StripePaymentSheet)
        // Publishable key is required client-side, but the backend URL falls
        // back to the bundled Cloudflare worker so card checkout works without
        // requiring users to type a backend URL into Payment Settings.
        guard !StripeConfig.publishableKey.isEmpty else {
            throw PaymentError.notConfigured
        }

        paymentStatus = .preparing
        isProcessing = true

        let amountInCents = NSDecimalNumber(decimal: amount * 100).intValue

        // StripeConfig.backendBaseURL now falls back to the deployed worker itself,
        // so the local fallback copy of the URL is no longer needed.
        let baseURL = StripeConfig.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let intentURL = URL(string: "\(baseURL)/create-payment-intent") else {
            throw PaymentError.serverError("Invalid backend URL: \(baseURL)")
        }

        var request = URLRequest(url: intentURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&request)

        let body: [String: Any] = [
            "amount": amountInCents,
            "currency": currency.lowercased(),
            "metadata": [
                "listing_id": listingID,
                "seller_name": sellerName,
                "product_name": productName
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PaymentError.serverError("No HTTP response from \(intentURL.absoluteString)")
        }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let serverMessage: String = {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = json["error"] as? String { return msg }
                return bodyText.isEmpty ? "(empty body)" : bodyText
            }()
            throw PaymentError.serverError("HTTP \(httpResponse.statusCode) from \(intentURL.absoluteString): \(serverMessage)")
        }

        let intentResponse = try JSONDecoder().decode(PaymentIntentResponse.self, from: data)

        var config = PaymentSheet.Configuration()
        config.merchantDisplayName = "Frydge Marketplace"
        config.allowsDelayedPaymentMethods = false

        if let customerId = intentResponse.customerId,
           let ephemeralKey = intentResponse.ephemeralKey {
            config.customer = .init(id: customerId, ephemeralKeySecret: ephemeralKey)
        }

        paymentSheet = PaymentSheet(
            paymentIntentClientSecret: intentResponse.clientSecret,
            configuration: config
        )

        paymentStatus = .ready
        isProcessing = false
        #else
        throw PaymentError.sdkNotAvailable
        #endif
    }

    /// Builds the PaymentSheet from a PaymentIntent that was already created
    /// server-side — e.g. by `MarketplaceOrderService.createOrder`, which makes
    /// the order record and the intent in one call so they can never diverge.
    func preparePayment(clientSecret: String) throws {
        #if canImport(StripePaymentSheet)
        guard !StripeConfig.publishableKey.isEmpty else {
            throw PaymentError.notConfigured
        }

        paymentStatus = .preparing
        isProcessing = true

        var config = PaymentSheet.Configuration()
        config.merchantDisplayName = "Frydge Marketplace"
        config.allowsDelayedPaymentMethods = false

        paymentSheet = PaymentSheet(
            paymentIntentClientSecret: clientSecret,
            configuration: config
        )

        paymentStatus = .ready
        isProcessing = false
        #else
        throw PaymentError.sdkNotAvailable
        #endif
    }

    // MARK: - Present Payment Sheet

    func presentPaymentSheet() async -> Bool {
        #if canImport(StripePaymentSheet)
        guard let sheet = paymentSheet else {
            paymentStatus = .failed("Payment not prepared")
            return false
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            paymentStatus = .failed("Could not find root view controller")
            return false
        }

        let topVC = Self.topViewController(from: rootVC)

        return await withCheckedContinuation { continuation in
            sheet.present(from: topVC) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .completed:
                        self?.paymentStatus = .completed
                        self?.paymentSheet = nil
                        continuation.resume(returning: true)
                    case .canceled:
                        self?.paymentStatus = .cancelled
                        continuation.resume(returning: false)
                    case .failed(let error):
                        self?.paymentStatus = .failed(error.localizedDescription)
                        continuation.resume(returning: false)
                    }
                }
            }
        }
        #else
        paymentStatus = .failed("Stripe SDK not installed")
        return false
        #endif
    }

    func reset() {
        paymentStatus = .idle
        isProcessing = false
        #if canImport(StripePaymentSheet)
        paymentSheet = nil
        #endif
    }

    private static func topViewController(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topViewController(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        return vc
    }
}

// MARK: - Errors

enum PaymentError: LocalizedError {
    case notConfigured
    case serverError(String)
    case sdkNotAvailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Stripe publishable key not set. Add it in Payment Settings."
        case .serverError(let detail):
            return "Failed to create payment. \(detail)"
        case .sdkNotAvailable:
            return "Stripe SDK is not installed. Add the stripe-ios package to your project."
        }
    }
}
