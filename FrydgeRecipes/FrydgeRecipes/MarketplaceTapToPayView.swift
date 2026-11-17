//
//  MarketplaceTapToPayView.swift
//  FrydgeRecipes
//
//  Seller-side Tap to Pay collection for P2P marketplace listings.
//
//  Small vendors sell face to face: the buyer turns up, the seller opens their
//  own listing and taps "Collect Payment", and the buyer taps their card or
//  phone on the seller's iPhone. This uses the same Stripe Terminal stack as
//  the clerk/store system but authenticates through the marketplace worker
//  (platform account, relay key) so sellers never need store credentials —
//  and the platform cut is the smaller marketplace fee, not the store one.
//

import SwiftUI

struct MarketplaceTapToPayView: View {
    let listing: P2PListing
    /// Called with `true` after a captured payment, `false` on cancel.
    let onComplete: (Bool) -> Void

    @StateObject private var terminal = TerminalManager.shared
    @State private var state: TapToPayView.TapState = .ready
    @State private var errorMessage: String?
    @State private var orderId: String?
    @State private var pendingClientSecret: String?
    /// One ID per sale, sent on every order-create retry so the server returns
    /// the same order and PaymentIntent even if the first response was lost
    /// before `pendingClientSecret` could be stored.
    @State private var saleAttemptId = UUID().uuidString

    private var amountCents: Int {
        NSDecimalNumber(decimal: listing.price * 100).intValue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Text(listing.formattedPrice)
                        .font(.system(size: 64, weight: .black, design: .rounded))
                    Text(listing.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    switch state {
                    case .ready:
                        stateView(icon: "wave.3.right.circle.fill", color: .blue,
                                  title: "Ready to collect",
                                  subtitle: "Tap below, then have the buyer hold their card or phone to your iPhone")
                    case .connecting:
                        ProgressView().scaleEffect(2).padding()
                        Text("Connecting...").font(.headline)
                    case .waiting:
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 80)).foregroundColor(.blue).symbolEffect(.pulse)
                        Text("Hold card near top of iPhone").font(.title2.bold())
                        Text("Card · Apple Pay · Google Pay · Apple Watch")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                    case .processing:
                        ProgressView().scaleEffect(2).padding()
                        Text("Processing...").font(.headline)
                    case .success:
                        stateView(icon: "checkmark.circle.fill", color: .green,
                                  title: "Payment Successful!", subtitle: nil)
                    case .failed:
                        stateView(icon: "xmark.circle.fill", color: .red,
                                  title: "Payment Failed", subtitle: errorMessage)
                    case .entitlementPending:
                        stateView(icon: "iphone.radiowaves.left.and.right", color: .blue,
                                  title: "Tap to Pay is linked",
                                  subtitle: entitlementPendingMessage)
                    }
                }
                .frame(maxWidth: .infinity).padding(28)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(20).padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    if state == .ready || state == .failed {
                        Button { Task { await collect() } } label: {
                            Label(state == .failed ? "Try Again" : "Start Tap to Pay", systemImage: "wave.3.right")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.blue).cornerRadius(16)
                        }.padding(.horizontal)
                        Button("Cancel") { onComplete(false) }.foregroundColor(.secondary)
                    }
                    if state == .success {
                        Button { onComplete(true) } label: {
                            Text("Done").font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.green).cornerRadius(16)
                        }.padding(.horizontal)
                    }
                    if state == .entitlementPending {
                        Button("Close") { onComplete(false) }.foregroundColor(.secondary)
                    }
                }.padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Collect Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state == .ready {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { onComplete(false) }
                    }
                }
            }
        }
        .interactiveDismissDisabled(state == .waiting || state == .processing)
    }

    @ViewBuilder
    private func stateView(icon: String, color: Color, title: String, subtitle: String?) -> some View {
        Image(systemName: icon).font(.system(size: 80)).foregroundColor(color)
        Text(title).font(.title2.bold()).foregroundColor(color)
        if let sub = subtitle {
            Text(sub).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }

    private func collect() async {
        errorMessage = nil
        state = .connecting

        do {
            // Reuse the order across retries so a network blip doesn't mint a
            // second PaymentIntent for the same sale.
            let clientSecret: String
            if let existing = pendingClientSecret {
                clientSecret = existing
            } else {
                let order = try await MarketplaceOrderService.shared.createInPersonOrder(
                    attemptId: saleAttemptId,
                    amount: amountCents,
                    currency: listing.currency,
                    listingId: listing.id.uuidString,
                    listingTitle: listing.title
                )
                orderId = order.orderId
                pendingClientSecret = order.clientSecret
                clientSecret = order.clientSecret
            }

            try await terminal.collectMarketplacePayment(clientSecret: clientSecret) { newState in
                Task { @MainActor in state = newState }
            }
        } catch {
            if isTapToPayEntitlementPending(error) {
                state = .entitlementPending
                errorMessage = entitlementPendingMessage
            } else {
                state = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private var entitlementPendingMessage: String {
        "The order and Stripe are connected. Apple reader access is waiting on the Tap to Pay entitlement approval, so no charge was captured."
    }

    private func isTapToPayEntitlementPending(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("operation not permitted")
            || message.contains("necessary entitlements")
            || message.contains("application bundle is valid")
            || message.contains("proximity")
    }
}
