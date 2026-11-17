//
//  SnackPickerSheet.swift
//  FrydgeRecipes
//
//  "I'm snacking on this" — a list of what's already in the fridge (personal
//  or shared), with the same usage stepper as the main list, for logging a
//  bite outside of any recipe (some chicken, a few carrots, ...).
//
//  The search bar sits at the bottom, thumb-reachable, and searches *all*
//  foods: what's in the fridge first, then the app's food catalogue, so a
//  snack that isn't in the fridge yet can be added and logged in one tap.
//  A barcode button at the far right of the bar scans a packet instead;
//  the product is matched against the fridge first and only added as a
//  brand-new item when nothing already there matches.
//

import SwiftUI
import UIKit

/// One snackable item plus how to log usage against it — the same shape
/// whether it lives in "Mine" or a shared frydge, so the sheet itself never
/// needs to know which.
struct SnackableItem: Identifiable {
    let item: StoredIngredient
    let onUsageChange: (Double) -> Void
    /// Non-nil for shared-frydge items, so the detail sheet's delete/location
    /// edits route through `SharedFridgeManager` instead of the personal
    /// `FrydgeManager`. Mirrors `SharedFrydgeView.sharedActions(for:)`.
    let actions: IngredientEditActions?

    var id: UUID { item.id }
}

struct SnackPickerSheet: View {
    let items: [SnackableItem]

    @EnvironmentObject private var frydgeManager: FrydgeManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var detailItem: SnackableItem?

    // Items added this session via search/barcode, layered on top of `items`
    // (a fixed snapshot from presentation time) so a freshly added snack
    // shows up immediately without having to reopen the sheet.
    @State private var addedItems: [SnackableItem] = []

    // Barcode scan
    @State private var showBarcodeScanner = false
    @State private var scannedBarcode: String = ""
    @State private var scannedProductDetails: ProductProtocol? = nil
    @State private var scanAlertMessage: String? = nil

    private var allItems: [SnackableItem] { items + addedItems }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Fridge items, A–Z, narrowed by the search.
    private var filteredFridge: [SnackableItem] {
        let sorted = allItems.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.item.name.localizedCaseInsensitiveContains(query) }
    }

    /// Foods from the catalogue (every food the app knows plus the common
    /// list) that match the search and aren't already in the fridge. The
    /// typed text itself is offered first so anything can be logged.
    private var catalogueMatches: [String] {
        guard query.count >= 2 else { return [] }
        let fridgeIndex = IngredientMatcher.Index(names: allItems.map(\.item.name))
        var seen = Set<String>()
        var out: [String] = []

        func consider(_ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key), name.localizedCaseInsensitiveContains(query) else { return }
            // Already in the fridge (by food family) → it's in the section above.
            guard fridgeIndex.firstMatch(forName: name) == nil else { return }
            seen.insert(key)
            out.append(name)
        }

        // Exact typed text first, then the catalogue, prefix matches before contains.
        consider(query)
        let pool = CommonFoodPreloader.baseFoods + FoodEmoji.allKeywords
        let lowered = query.lowercased()
        for food in pool where food.lowercased().hasPrefix(lowered) { consider(food) }
        for food in pool { consider(food) }
        return Array(out.prefix(24))
    }

    var body: some View {
        NavigationStack {
            Group {
                if allItems.isEmpty && query.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in your fridge yet", systemImage: "refrigerator")
                    } description: {
                        Text("Search any food below to log a snack, or add a few items to your fridge first.")
                    }
                } else if filteredFridge.isEmpty && catalogueMatches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if !filteredFridge.isEmpty {
                                if !query.isEmpty {
                                    sectionHeader("In your fridge", systemImage: "refrigerator")
                                }
                                ForEach(filteredFridge) { entry in
                                    FridgeItemRow(
                                        item: entry.item,
                                        onTapDetail: { detailItem = entry },
                                        onUsageChange: entry.onUsageChange,
                                        onAddToList: {}
                                    )
                                }
                            }

                            if !catalogueMatches.isEmpty {
                                sectionHeader("All foods", systemImage: "magnifyingglass")
                                    .padding(.top, filteredFridge.isEmpty ? 0 : 8)
                                ForEach(catalogueMatches, id: \.self) { food in
                                    catalogueRow(food)
                                }
                            }
                            Color.clear.frame(height: 12)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 3)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Snack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Done lives on the right; nothing on the left.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // Bottom search bar: thumb-reachable, with the barcode scanner on
            // the far right end.
            .safeAreaInset(edge: .bottom) {
                bottomSearchBar
            }
            .sheet(item: $detailItem) { entry in
                IngredientDetailSheet(ingredient: entry.item, actions: entry.actions) { newUsage in
                    entry.onUsageChange(newUsage)
                }
                .environmentObject(frydgeManager)
            }
            .fullScreenCover(isPresented: $showBarcodeScanner) {
                BarcodeScannerView(
                    isShowing: $showBarcodeScanner,
                    scannedBarcode: $scannedBarcode,
                    productDetails: $scannedProductDetails
                )
                .ignoresSafeArea()
                .onDisappear { handleScannedBarcode() }
            }
            .alert(
                "Couldn't add snack",
                isPresented: Binding(
                    get: { scanAlertMessage != nil },
                    set: { if !$0 { scanAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanAlertMessage ?? "")
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    /// A food that isn't in the fridge yet: tap to add it and log a bite.
    private func catalogueRow(_ food: String) -> some View {
        Button {
            resolveSnack(name: food.localizedCapitalized, quantity: "1")
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemGray6))
                    Text(FoodEmoji.emoji(for: food))
                        .font(.title3)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(food.localizedCapitalized)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Not in your fridge · tap to add and snack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(FridgeItemRow.glassMaterial)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(food) and snack on it")
    }

    private var bottomSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Search all foods", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        // Return with nothing in the fridge matching → log the typed food.
                        if filteredFridge.isEmpty, let first = catalogueMatches.first {
                            resolveSnack(name: first.localizedCapitalized, quantity: "1")
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                isSearchFocused = false
                showBarcodeScanner = true
            } label: {
                Image(systemName: "barcode.viewfinder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan a barcode")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Barcode → snack

    private func handleScannedBarcode() {
        guard let details = scannedProductDetails else { return }
        scannedProductDetails = nil
        let name = (details.productName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.caseInsensitiveCompare("Unknown") != .orderedSame else {
            scanAlertMessage = "Couldn't identify that barcode. Try searching for it instead."
            return
        }
        resolveSnack(name: name, quantity: "1")
    }

    // MARK: - Match or add

    /// Matches a scanned/typed name against what's already in the fridge and
    /// opens it to log a bite; if nothing matches, adds it as a brand-new
    /// fridge item first so it behaves exactly like anything else on this list.
    @MainActor
    private func resolveSnack(name: String, quantity: String) {
        let pool = allItems
        let index = IngredientMatcher.Index(names: pool.map { $0.item.name })
        if let position = index.firstMatch(forName: name) {
            detailItem = pool[position]
            return
        }

        frydgeManager.addAutoClassifiedProduct(
            name: name,
            quantity: quantity.isEmpty ? "1" : quantity,
            unit: "",
            lifecycle: .fridge
        )

        guard let newStored = frydgeManager.storedIngredients.last(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.lifecycle == .fridge
        }) else { return }

        let newEntry = SnackableItem(
            item: newStored,
            onUsageChange: { frydgeManager.setQuantityUsed(for: newStored.id, to: $0) },
            actions: nil
        )
        addedItems.append(newEntry)
        searchText = ""
        detailItem = newEntry
    }
}
