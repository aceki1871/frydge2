//
//  MarketplaceOrdersView.swift
//  FrydgeRecipes
//
//  Buyer and seller order history for the marketplace, backed by
//  MarketplaceOrderService. Buyers confirm receipt here; sellers mark
//  orders ready for collection.
//

import SwiftUI

struct MarketplaceOrdersView: View {
    @StateObject private var orderService = MarketplaceOrderService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var role: MarketplaceOrderService.Role = .buyer
    @State private var actionError: String?
    @State private var showActionError = false
    @State private var busyOrderId: String?

    private var orders: [MarketplaceOrder] {
        role == .buyer ? orderService.buyerOrders : orderService.sellerOrders
    }

    private var isSignedIn: Bool { MarketplaceIdentity.currentUserID != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Role", selection: $role) {
                    Text("Purchases").tag(MarketplaceOrderService.Role.buyer)
                    Text("Sales").tag(MarketplaceOrderService.Role.seller)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                content
            }
            .navigationTitle("Orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await orderService.refreshOrders(role: role) }
            .onChange(of: role) { _, newRole in
                Task { await orderService.refreshOrders(role: newRole) }
            }
            .alert("Order Error", isPresented: $showActionError) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "Something went wrong.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isSignedIn {
            ContentUnavailableView {
                Label("Sign in to see orders", systemImage: "icloud")
            } description: {
                Text("Orders are tied to your iCloud account so both buyer and seller see the same record. Sign in to iCloud in Settings, then come back.")
            }
        } else if orderService.isLoading && orders.isEmpty {
            Spacer()
            ProgressView("Loading orders…")
            Spacer()
        } else if let error = orderService.lastError, orders.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load orders", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task { await orderService.refreshOrders(role: role) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if orders.isEmpty {
            ContentUnavailableView {
                Label(
                    role == .buyer ? "No Purchases" : "No Sales",
                    systemImage: role == .buyer ? "bag" : "banknote"
                )
            } description: {
                Text(role == .buyer
                     ? "Items you buy in the marketplace will show up here."
                     : "When someone buys one of your listings, the order appears here.")
            } actions: {
                Button(role == .buyer ? "Browse Marketplace" : "List an Item") { dismiss() }
            }
        } else {
            List {
                if let error = orderService.lastError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(orders) { order in
                    MarketplaceOrderRow(
                        order: order,
                        role: role,
                        isBusy: busyOrderId == order.id,
                        onAction: { performAction(on: order) }
                    )
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await orderService.refreshOrders(role: role) }
        }
    }

    /// The single role-appropriate state transition for this order:
    /// seller marks ready, buyer confirms receipt.
    private func performAction(on order: MarketplaceOrder) {
        busyOrderId = order.id
        Task {
            defer { busyOrderId = nil }
            do {
                switch role {
                case .seller: try await MarketplaceOrderService.shared.markReady(orderId: order.id)
                case .buyer:  try await MarketplaceOrderService.shared.confirmReceived(orderId: order.id)
                }
            } catch {
                actionError = error.localizedDescription
                showActionError = true
            }
        }
    }
}

// MARK: - Row

private struct MarketplaceOrderRow: View {
    let order: MarketplaceOrder
    let role: MarketplaceOrderService.Role
    let isBusy: Bool
    let onAction: () -> Void

    private var statusColor: Color {
        switch order.status {
        case .paid, .ready:              return .blue
        case .received:                  return .green
        case .pendingPayment:            return .orange
        case .cancelled, .paymentFailed: return .red
        case .refunded, .disputed:       return .purple
        }
    }

    private var actionLabel: String? {
        switch role {
        case .seller: return order.canMarkReady ? "Mark ready for collection" : nil
        case .buyer:  return order.canConfirmReceipt ? "Confirm received" : nil
        }
    }

    /// One line telling this party what happens next, so the status chip
    /// isn't the only clue.
    private var nextStep: String? {
        switch (role, order.status) {
        case (.seller, .paid):           return "Payment received — get the item ready, then mark it."
        case (.seller, .ready):          return "Waiting for the buyer to collect and confirm."
        case (.seller, .received):       return "Done. Your payout follows Stripe's schedule."
        case (.buyer, .paid):            return "Paid. The seller will let you know when it's ready."
        case (.buyer, .ready):           return "Ready to collect — confirm once you have it."
        case (.buyer, .received):        return "Enjoy! Thanks for buying local."
        case (_, .pendingPayment):       return "Payment hasn't gone through yet."
        case (_, .paymentFailed):        return "The payment failed. Nothing was charged."
        case (_, .refunded):             return "Refunded to the original payment method."
        case (_, .disputed):             return "Under review with the card issuer."
        case (_, .cancelled):            return nil
        }
    }

    private var isInPersonSale: Bool { order.buyerUserId == "in-person" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.listingTitle ?? "Marketplace item")
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if isInPersonSale {
                            Text("·")
                            Label("Tap to Pay", systemImage: "wave.3.right")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(order.formattedAmount)
                        .font(.headline)

                    Text(order.status.displayName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor)
                }
            }

            if order.quantity > 1 {
                Text("Quantity: \(order.quantity)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let nextStep {
                Text(nextStep)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let actionLabel {
                Button(action: onAction) {
                    if isBusy {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(actionLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MarketplaceOrdersView()
}
