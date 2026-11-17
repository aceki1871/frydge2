import SwiftUI
import PassKit

struct MarketplaceCheckoutView: View {
    let listing: P2PListing
    let onPaymentComplete: () -> Void

    @StateObject private var paymentService = StripePaymentService.shared
    @StateObject private var applePayHandler = ApplePaymentHandler()
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        productSummary
                        orderSummary

                        if let w3w = listing.what3WordsLocation, !w3w.isEmpty {
                            pickupSummary(w3w)
                        }

                        // Developer-facing configuration hints. Buyers on a
                        // release build get the plain message in payButton.
                        #if DEBUG
                        if !StripeConfig.canUseInAppCardCheckout {
                            stripeSDKMissingBanner
                        }

                        if !StripeConfig.isConfigured {
                            stripeNotConfiguredBanner
                        }
                        #endif
                    }
                    .padding()
                }

                payButton
                    // Attached here (not on the NavigationStack content) so it
                    // doesn't collide with the "Payment Error" alert below —
                    // two .alert modifiers on the same view is unreliable and
                    // one silently never presents.
                    .alert("Payment Successful", isPresented: $showSuccess) {
                        Button("Done") {
                            onPaymentComplete()
                            dismiss()
                        }
                    } message: {
                        Text("Your payment for \(listing.title) has been processed successfully.")
                    }
            }
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Payment Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .onChange(of: paymentService.paymentStatus) { _, newStatus in
                if case .failed(let message) = newStatus {
                    errorMessage = message
                    showError = true
                }
            }
            .onChange(of: applePayHandler.paymentStatus) { _, newStatus in
                switch newStatus {
                case .success:
                    showSuccess = true
                case .failed:
                    errorMessage = applePayHandler.errorMessage ?? "Apple Pay failed."
                    showError = true
                default:
                    break
                }
            }
        }
    }

    // MARK: - Product Summary

    private var productSummary: some View {
        HStack(spacing: 16) {
            if let imageData = listing.imageData,
               let uiImage = UIImage.frydgeBounded(data: imageData, maxPixelSize: ImageBudget.display) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.15))
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80, height: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title)
                    .font(.headline)

                Text("Sold by \(listing.sellerName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Order Summary

    private var orderSummary: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Order Summary")
                    .font(.headline)
                Spacer()
            }

            Divider()

            HStack {
                Text("Item price")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(listing.formattedPrice)
            }

            Divider()

            HStack {
                Text("Total")
                    .font(.headline)
                Spacer()
                Text(listing.formattedPrice)
                    .font(.headline)
                    .foregroundStyle(.accent)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stripe Not Configured Banner

    private var stripeNotConfiguredBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            Text("Stripe Not Configured")
                .font(.headline)

            Text("To enable card payments, configure your Stripe publishable key and backend URL in the app settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var stripeSDKMissingBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            Text("Stripe Checkout SDK Missing")
                .font(.headline)

            Text("Add StripePaymentSheet to the Xcode package dependencies to present in-app card checkout for marketplace listings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Pay Button

    private var payButton: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 12) {
                // Apple Pay — shown first when available (preferred)
                if applePayHandler.canMakePayments {
                    ApplePayButton(type: .buy, style: .automatic) {
                        payWithApplePay()
                    }
                    .frame(height: 50)
                    .cornerRadius(12)
                    .disabled(applePayHandler.paymentStatus == .preparingIntent ||
                              applePayHandler.paymentStatus == .processing)
                }

                // Fallback: Stripe card checkout (requires StripePaymentSheet SDK)
                if canUseCheckout {
                    Button {
                        Task { await processPayment() }
                    } label: {
                        Group {
                            if paymentService.isProcessing {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Processing...")
                                }
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "creditcard.fill")
                                    Text("Pay by card  \(listing.formattedPrice)")
                                }
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo))
                    }
                    .disabled(paymentService.isProcessing)
                }

                if !applePayHandler.canMakePayments && !canUseCheckout {
                    // Neither Apple Pay nor card checkout can run here. Say so
                    // plainly rather than presenting an empty footer.
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        Text("Online payment isn't available on this device right now. Arrange payment with the seller at pickup — they can take cards and Apple Pay with Tap to Pay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Powered by Stripe · You'll only be charged once the payment is confirmed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Pickup

    /// Where the buyer collects from, so they see it before paying rather than
    /// having to go back to the listing afterwards.
    private func pickupSummary(_ w3w: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pickup from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("///\(w3w)")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Payment Processing

    /// Listing price in the smallest currency unit.
    private var amountInCents: Int {
        NSDecimalNumber(decimal: listing.price * 100).intValue
    }

    /// Marketplace platform fee, only when the payment routes through Stripe
    /// Connect. Mirrors ApplePaymentHandler's direct-charge policy.
    private var platformFeeAmount: Int? {
        guard listing.sellerStripeAccountId != nil else { return nil }
        return MarketplaceFees.fee(forCents: amountInCents)
    }

    /// One ID per checkout, reused across every retry (tap again after a
    /// network error, switch from card to Apple Pay) so the server returns the
    /// same order and PaymentIntent instead of creating a second charge. A new
    /// ID is issued only once a payment has succeeded.
    @State private var checkoutAttemptId = UUID().uuidString

    /// Creates the durable order record and its PaymentIntent in one server
    /// call, so a payment can never be taken without an order to attach it to.
    private func createOrder() async throws -> (orderId: String, paymentIntentId: String, clientSecret: String) {
        try await MarketplaceOrderService.shared.createOrder(
            attemptId: checkoutAttemptId,
            amount: amountInCents,
            currency: listing.currency,
            sellerUserId: listing.sellerID,
            listingId: listing.id.uuidString,
            listingTitle: listing.title,
            applicationFeeAmount: platformFeeAmount
        )
    }

    private func payWithApplePay() {
        Task {
            do {
                let order = try await createOrder()

                // Build a VendorProduct wrapper from the P2PListing; the preset
                // intent means ApplePaymentHandler confirms the order's intent
                // instead of creating an orphan one.
                let proxy = VendorProduct(
                    id: listing.id.uuidString,
                    name: listing.title,
                    description: listing.description,
                    price: listing.price,
                    currency: listing.currency,
                    vendorID: listing.sellerID,
                    vendorName: listing.sellerName
                )
                applePayHandler.startPayment(
                    for: proxy,
                    quantity: 1,
                    sellerAccountId: listing.sellerStripeAccountId,
                    presetPaymentIntentId: order.paymentIntentId
                ) { success in
                    if success {
                        showSuccess = true
                        checkoutAttemptId = UUID().uuidString  // this attempt is spent
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func processPayment() async {
        guard canUseCheckout else {
            errorMessage = StripeConfig.canUseInAppCardCheckout
                ? "Stripe is not configured. Add your publishable key and backend URL in Payment Settings."
                : "StripePaymentSheet is not installed. Add the Stripe iOS PaymentSheet package to enable in-app card checkout."
            showError = true
            return
        }

        do {
            let order = try await createOrder()
            try paymentService.preparePayment(clientSecret: order.clientSecret)

            let success = await paymentService.presentPaymentSheet()
            if success {
                showSuccess = true
                checkoutAttemptId = UUID().uuidString  // this attempt is spent
            }
            paymentService.reset()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            paymentService.reset()
        }
    }

    private var canUseCheckout: Bool {
        StripeConfig.canUseInAppCardCheckout && StripeConfig.isConfigured
    }
}

// MARK: - Apple Pay Button (UIViewRepresentable bridge)

struct ApplePayButton: UIViewRepresentable {
    var type: PKPaymentButtonType
    var style: PKPaymentButtonStyle
    var action: () -> Void

    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: type, paymentButtonStyle: style)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: PKPaymentButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

// MARK: - Stripe Settings View (for ProfileView or Settings)

struct StripeSettingsView: View {
    @State private var publishableKey: String = ""
    @State private var backendURL: String = ""
    @State private var showSaved = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Payment Configuration", systemImage: "creditcard.fill")
                        .font(.headline)
                    Text("Configure Stripe to accept card payments in the marketplace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Stripe Keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Publishable Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("pk_live_...", text: $publishableKey)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Backend URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://your-server.example.com", text: $backendURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
            }

            Section {
                Button("Save Configuration") {
                    StripeConfig.configure(
                        publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        backendURL: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    showSaved = true
                }
                .disabled(publishableKey.isEmpty || backendURL.isEmpty)
            }

            Section("Backend Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your server needs a POST endpoint at /create-payment-intent that:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Accepts: amount, currency, metadata")
                        Text("2. Creates a Stripe PaymentIntent")
                        Text("3. Returns: clientSecret, ephemeralKey, customerId")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if StripeConfig.isConfigured {
                Section {
                    Label("Stripe is configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Payment Settings")
        .onAppear {
            publishableKey = StripeConfig.publishableKey
            backendURL = StripeConfig.backendBaseURL
        }
        .alert("Saved", isPresented: $showSaved) {
            Button("OK") {}
        } message: {
            Text("Stripe configuration has been saved.")
        }
    }
}
