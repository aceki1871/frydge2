//
//  StripeConfig.swift
//  FrydgeRecipes
//
//  Stripe configuration and setup
//

import Foundation
#if canImport(StripePaymentSheet)
import StripePaymentSheet
#endif

/// Configuration for Stripe payments
struct StripeConfig {
    // MARK: - Configuration Keys
    
    private static let publishableKeyKey = "stripe_publishable_key"
    private static let backendURLKey = "stripe_backend_url"
    private static let merchantIdentifierKey = "stripe_merchant_identifier"
    private static let terminalLocationIdKey = "stripe_terminal_location_id"
    
    // MARK: - Default Values
    
    /// Bundled publishable key so the app can take payments out of the box with
    /// zero setup. Publishable keys are safe to ship in the client (they're public
    /// by design; the secret key lives only on the Cloudflare worker). Swap this
    /// to a `pk_live_…` key for real charges — and make sure the worker holds the
    /// matching live secret.
    static let bundledPublishableKey = "pk_test_51TSViXCVYZKUKvUzJnn2qkhypIB7txxKzub2bZylpgmKyLJ6WCckN7iyITlSRoLW4uAcrWadY7TzFbzCZxs6c2ye00PHo3E4tG"

    /// Your Stripe publishable key (starts with pk_test_ or pk_live_).
    /// Falls back to the bundled key so payments work without manual setup.
    static var publishableKey: String {
        get {
            let stored = UserDefaults.standard.string(forKey: publishableKeyKey) ?? ""
            return stored.isEmpty ? bundledPublishableKey : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: publishableKeyKey)
        }
    }

    /// Point the Stripe SDK at the effective publishable key. Call once at launch
    /// so Apple Pay / PaymentSheet work without the user opening any setup screen.
    static func applyToStripeSDK() {
        #if canImport(StripePaymentSheet)
        StripeAPI.defaultPublishableKey = publishableKey
        #endif
    }
    
    /// The live Stripe worker. Single source of truth for the backend URL —
    /// `StripeConnectManager` and `ApplePaymentHandler` each used to hardcode this
    /// string separately, so changing it meant changing it in three places.
    static let defaultBackendBaseURL = "\(FrydgeBackend.host)/stripe"

    /// The Apple Pay merchant ID from `FrydgeRecipes.entitlements`.
    /// Must match `com.apple.developer.in-app-payments` exactly or Apple Pay fails
    /// at runtime with no useful error.
    static let defaultMerchantIdentifier = "merchant.com.Clark-Online.Recipe"

    /// Your backend server URL for creating PaymentIntents.
    ///
    /// Defaults to the deployed worker so the app works out of the box — it used
    /// to default to "" , which left `isConfigured` false until a user happened to
    /// find the setup screen.
    static var backendBaseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: backendURLKey) ?? ""
            return stored.isEmpty ? defaultBackendBaseURL : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: backendURLKey)
        }
    }

    /// Your Apple Merchant Identifier (for Apple Pay).
    ///
    /// Previously defaulted to the template placeholder
    /// "merchant.com.yourcompany.frydge", which does not exist and silently broke
    /// Apple Pay for anyone who hadn't run setup.
    static var merchantIdentifier: String {
        get {
            let stored = UserDefaults.standard.string(forKey: merchantIdentifierKey) ?? ""
            return stored.isEmpty ? defaultMerchantIdentifier : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: merchantIdentifierKey)
        }
    }

    /// Stripe Terminal Location ID used to register Tap to Pay on iPhone.
    static var terminalLocationId: String {
        get {
            (UserDefaults.standard.string(forKey: terminalLocationIdKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: terminalLocationIdKey)
        }
    }
    
    // MARK: - Configuration
    
    /// `backendBaseURL` now always resolves to at least the default worker, so the
    /// only thing that can actually be missing is the publishable key.
    static var isConfigured: Bool {
        !publishableKey.isEmpty && !backendBaseURL.isEmpty
    }

    static var hasTerminalLocation: Bool {
        terminalLocationId.hasPrefix("tml_")
    }

    static var canUseInAppCardCheckout: Bool {
        #if canImport(StripePaymentSheet)
        true
        #else
        false
        #endif
    }
    
    static func configure(
        publishableKey: String,
        backendURL: String,
        merchantIdentifier: String? = nil,
        terminalLocationId: String? = nil
    ) {
        self.publishableKey = publishableKey
        self.backendBaseURL = backendURL
        if let merchantIdentifier = merchantIdentifier {
            self.merchantIdentifier = merchantIdentifier
        }
        if let terminalLocationId = terminalLocationId {
            self.terminalLocationId = terminalLocationId
        }
        #if canImport(StripePaymentSheet)
        StripeAPI.defaultPublishableKey = publishableKey
        #endif
    }
}

/// Payment Intent response from your backend
struct PaymentIntentResponse: Codable {
    let clientSecret: String
    let ephemeralKey: String?
    let customerId: String?
    let publishableKey: String?
}

/// Service to communicate with your Stripe backend
actor StripeBackendService {
    static let shared = StripeBackendService()
    
    private init() {}
    
    /// Create a PaymentIntent on your backend
    func createPaymentIntent(amount: Int, currency: String, metadata: [String: String] = [:]) async throws -> PaymentIntentResponse {
        guard !StripeConfig.backendBaseURL.isEmpty else {
            throw StripeError.notConfigured
        }
        
        let url = URL(string: "\(StripeConfig.backendBaseURL)/create-payment-intent")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&request)
        
        let body: [String: Any] = [
            "amount": amount,
            "currency": currency,
            "metadata": metadata
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StripeError.backendError
        }
        
        return try JSONDecoder().decode(PaymentIntentResponse.self, from: data)
    }
}

enum StripeError: LocalizedError {
    case notConfigured
    case backendError
    case paymentFailed
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Stripe is not configured. Please add your publishable key and backend URL in Settings."
        case .backendError:
            return "Unable to connect to payment server. Please try again."
        case .paymentFailed:
            return "Payment failed. Please try again or use a different payment method."
        }
    }
}
