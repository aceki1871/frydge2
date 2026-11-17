//
//  AppState.swift
//  FrydgeRecipes
//
//  Created by Josh on 23/10/2024.
//


import SwiftUI

/// Payment requested via `frydge://collect?orderId=…&amount=…&cs=…&orgId=…`.
struct PendingPayment: Equatable, Identifiable {
    let orderId: String
    let orgId: String?
    let amount: Double
    let clientSecret: String
    let customerName: String?

    var id: String { orderId }
}

struct AppBanner: Equatable, Identifiable {
    enum Style: Equatable {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let title: String
    let message: String?
    let systemImage: String
    let style: Style
}

/// A shopping item the store-arrival notification asked us to open. The id
/// may not resolve (the item could have been bought already), so the name is
/// carried too and the sheet falls back to a name-only item.
struct ShoppingItemDetailRequest: Equatable {
    let itemID: String
    let name: String
    /// The store the notification fired for, so the sheet can suggest what
    /// else to grab while the shopper is inside it.
    let storeName: String?
}

class AppState: ObservableObject {
    /// Set when a notification wants the shopping list to open an item's
    /// detail sheet. ShoppingListView clears it once presented.
    @Published var pendingShoppingItemDetail: ShoppingItemDetailRequest?

    @Published var lastViewedRecipeID: String? {
        didSet {
            if lastViewedRecipeID != nil {
                scheduleRecipeIDReset()
            }
        }
    }

    @Published var selectedTab: MainTabView.Tab = .frydge
    @Published var tabResetCounters: [MainTabView.Tab: Int] = [:]

    /// Bumped when a cook finishes so any transient fridge sheets (e.g. the
    /// ingredient detail sheet that launched the recipe) can dismiss themselves.
    @Published var dismissFridgeSheetsToken: Int = 0

    /// Set when another screen wants the shopping list to open the in-store
    /// basket (the lighter "what's my total" view). ShoppingListView clears it.
    @Published var openBasketRequested: Bool = false

    /// Jump to the shopping list and open the basket.
    @MainActor
    func openShoppingBasket() {
        selectedTab = .shoppingList
        openBasketRequested = true
    }

    /// Close out the cook loop: hop back to the Frydge tab and ask any open
    /// fridge sheets to dismiss so the user lands on the updated fridge.
    @MainActor
    func returnToFridgeAfterCook() {
        selectedTab = .frydge
        dismissFridgeSheetsToken += 1
    }

    @Published var pendingImportURL: URL?
    @Published var showImportSheet: Bool = false

    /// Set when an external `frydge://collect` deep link asks us to take payment.
    /// Cleared when the resulting payment screen is dismissed.
    @Published var pendingPayment: PendingPayment?

    /// Set when an external `frydge://create` deep link or the in-app + button
    /// requests the recipe creation flow.
    @Published var showCreateRecipe: Bool = false

    /// Set when a widget/live-activity scan deep link should open the product
    /// details flow. The sheet contains the barcode scanner entry point.
    @Published var showProductDetailsFromWidget: Bool = false
    @Published var productDetailsFromWidgetAutoStartScanner: Bool = false

    @Published var banner: AppBanner?

    private var expirationTimer: Timer?
    private var bannerTask: Task<Void, Never>?

    @MainActor
    func showBanner(
        title: String,
        message: String? = nil,
        systemImage: String = "bell",
        style: AppBanner.Style = .info,
        duration: TimeInterval = 4
    ) {
        bannerTask?.cancel()
        let nextBanner = AppBanner(
            title: title,
            message: message,
            systemImage: systemImage,
            style: style
        )
        banner = nextBanner

        bannerTask = Task { [weak self] in
            let delay = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard self?.banner?.id == nextBanner.id else { return }
                self?.banner = nil
            }
        }
    }

    @MainActor
    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    private func scheduleRecipeIDReset() {
        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.lastViewedRecipeID = nil
            print("Last viewed recipe ID has been reset.")
        }
    }
}

// MARK: - Adaptive app background colour

extension Color {
    static let appBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)   // medium grey — noticeably lighter than systemGroupedBackground
            : UIColor(white: 0.95, alpha: 1)   // off-white
    })
}
