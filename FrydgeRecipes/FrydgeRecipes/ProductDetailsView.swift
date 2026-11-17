//
//  ProductDetailsView.swift
//  FrydgeRecipes
//

import SwiftUI
import CloudKit
import UserNotifications

enum ProductContext {
    case recipe
    case fridge
    case shopping
    case sharedFridge(anchor: CKRecord, db: CKDatabase)
    case sharedShopping(anchor: CKRecord, db: CKDatabase)
}

struct ProductDetailsView: View {
    @Binding var isShowing: Bool
    @State var productDetails: ProductProtocol?

    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @Environment(\.dismiss) private var dismiss

    @State private var ingredientName: String = ""
    @State private var quantity: String = ""
    @State private var selectedUnit: String = "ea"
    @State private var expirationDate: Date = Date()
    @State private var isSaved: Bool = false
    @State private var locationTag: String = ""

    @State private var showScanner = false
    @State private var didAutoStartScanner = false
    @State private var scannedBarcode: String = ""
    @State private var scannedProductDetails: ProductProtocol? = nil

    @State private var customUnit: String = ""
    @State private var showCustomUnitField: Bool = false
    @State private var quickQty: Int = 1

    private let quickUnits = ["ea", "g", "kg", "ml", "L", "pack", "can", "bunch"]
    private let quickLocations = ["Fridge", "Freezer", "Dry"]
    @State private var dietaryTags: Set<String> = []
    @State private var showDietaryOptions = false
    @State private var showBBFPicker = false

    /// True once the user has actually run a search. Until then an empty result
    /// list means "hasn't looked yet", not "nothing found".
    @State private var hasSearched = false

    /// Set when a search fails (offline, server error) so we can say so, rather
    /// than showing the same "No products found" as a genuinely empty result.
    @State private var searchError: String? = nil

    /// True once the user picks their own best-before date, so the food-type
    /// default stops overriding it on save.
    @State private var didSetExpiryManually = false

    // MARK: - Availability
    @State private var isCheckingAvailability: Bool = false
    @State private var availabilityProductCandidates: [AvailabilityProductCandidate] = []
    @State private var availabilityOffersByCandidateID: [UUID: [StockAvailability.StoreOffer]] = [:]
    @State private var loadingAvailabilityCandidateIDs: Set<UUID> = []
    @State private var savedAvailabilityCandidateIDs: Set<UUID> = []

    // Per-candidate dietary tags and search debounce
    @State private var candidateDietaryTags: [UUID: Set<String>] = [:]
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    // Tap-to-preview for a search result
    @State private var previewCandidate: AvailabilityProductCandidate? = nil
    @State private var previewProduct: FrydgeProduct? = nil
    @State private var isLoadingPreview: Bool = false

    // Paste-a-link resolution (Open Food Facts / product pages → product + nutrition)
    @State private var isResolvingLink: Bool = false
    @State private var linkedProduct: OFFProduct? = nil
    @State private var showLinkedProduct: Bool = false
    @State private var linkResolveError: String? = nil

    // Multi-add session (fridge context): after each add the sheet returns to
    // a ready state instead of closing, and a brief toast confirms the add.
    @State private var addedCount: Int = 0
    @State private var addedToast: String? = nil
    @State private var addedToastTask: Task<Void, Never>? = nil

    /// Product images found in the products DB for results the price server
    /// returned without one. Filled in the background after a search.
    @State private var candidateImageOverrides: [UUID: URL] = [:]

    /// Nutrition facts shown in the result preview (shared detail component).
    @State private var previewFacts: ProductNutritionFacts? = nil

    // Secondary ways in (fridge context): scan a till receipt, or a written
    // list, to add many items at once. Each keeps its own review wizard.
    @State private var showReceiptScan = false
    @State private var showListScan = false
    @State private var showFridgeScan = false

    @FocusState private var focusedField: FocusField?
    private enum FocusField: Hashable {
        case item
        case quantity
        case customUnit
    }

    var context: ProductContext = .recipe
    var onAddToRecipe: ((String) -> Void)? = nil
    var onSaveItem: ((String) -> Void)? = nil
    var onSaveStructuredItem: ((String, String, String, String, [String]) -> Void)? = nil
    var onConfirm: ((OFFProduct) -> Void)? = nil
    var onConfirmStructured: ((String, String, String) -> Void)? = nil
    var autoStartScanner: Bool = false
    var recipeImage: UIImage? = nil
    var recipeTitle: String? = nil

    private var isFridgeContext: Bool {
        if case .fridge = context { return true }
        return false
    }

    /// True when the host supplied its own save handler (shared lists, the
    /// item edit sheet, the recipe editor). Those hosts own what "save" means,
    /// so the sheet must hand the entry back rather than writing to the
    /// personal list itself.
    private var hasCustomSaveHandler: Bool {
        onConfirm != nil || onConfirmStructured != nil || onSaveItem != nil
            || onSaveStructuredItem != nil || onAddToRecipe != nil
    }

    /// Personal shopping list only — `.shopping` with no custom handler.
    private var isShoppingContext: Bool {
        guard case .shopping = context else { return false }
        return !hasCustomSaveHandler
    }

    /// Fridge and personal shopping list share the same simple flow: type (or
    /// scan), tap add, see a toast, and the sheet resets for the next item.
    /// It only closes on Done.
    private var isQuickAddContext: Bool {
        isFridgeContext || isShoppingContext
    }

    private var destinationTitle: String {
        isFridgeContext ? "Fridge" : "List"
    }

    init(
        isShowing: Binding<Bool>,
        productDetails: ProductProtocol? = nil,
        context: ProductContext = .recipe,
        onAddToRecipe: ((String) -> Void)? = nil,
        onSaveItem: ((String) -> Void)? = nil,
        onSaveStructuredItem: ((String, String, String, String, [String]) -> Void)? = nil,
        onConfirm: ((OFFProduct) -> Void)? = nil,
        onConfirmStructured: ((String, String, String) -> Void)? = nil,
        autoStartScanner: Bool = false,
        recipeImage: UIImage? = nil,
        recipeTitle: String? = nil
    ) {
        self._isShowing = isShowing
        self._productDetails = State(initialValue: productDetails)
        self.context = context
        self.onAddToRecipe = onAddToRecipe
        self.onSaveItem = onSaveItem
        self.onSaveStructuredItem = onSaveStructuredItem
        self.onConfirm = onConfirm
        self.onConfirmStructured = onConfirmStructured
        self.autoStartScanner = autoStartScanner
        self.recipeImage = recipeImage
        self.recipeTitle = recipeTitle
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                searchBar

                Group {
                    if isResolvingLink {
                        loadingView
                    } else if ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptySearchPrompt
                    } else if isCheckingAvailability && availabilityProductCandidates.isEmpty {
                        loadingView
                    } else if let searchError {
                        searchErrorView(searchError)
                    } else if hasSearched && availabilityProductCandidates.isEmpty {
                        noResultsView
                    } else if availabilityProductCandidates.isEmpty {
                        // Typed something but hasn't tapped Search yet.
                        emptySearchPrompt
                    } else {
                        resultsList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && availabilityProductCandidates.isEmpty
                && !isCheckingAvailability
                && !isResolvingLink
                && detectedURL(in: ingredientName) == nil {
                quickSaveBar
            }
        }
        .overlay(alignment: .top) {
            if let addedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(addedToast)
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.green, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .toolbar { keyboardToolbar }
        .onAppear(perform: handleOnAppear)
        .onChange(of: ingredientName) { _, newValue in
            // Cancel any pending auto-search; don't trigger a new one.
            // Results are only cleared when the field is emptied, or when the user taps Search.
            searchDebounceTask?.cancel()
            // A new search term invalidates the previous result and its error.
            hasSearched = false
            searchError = nil
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearAvailabilityResults()
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            BarcodeScannerView(
                isShowing: $showScanner,
                scannedBarcode: $scannedBarcode,
                productDetails: $scannedProductDetails,
                onNutritionScanned: { _ in },
                onFrontLabelDetected: { detectedName in
                    applyDetectedItemName(detectedName)
                }
            )
            .onDisappear(perform: handleScannedProductDetails)
        }
        .sheet(item: $previewCandidate) { candidate in
            candidatePreviewSheet(for: candidate)
        }
        .sheet(isPresented: $showReceiptScan) {
            ReceiptScanView()
                .environmentObject(frydgeManager)
        }
        .sheet(isPresented: $showListScan) {
            // Scanned list items land wherever this sheet is adding to.
            ShoppingListScanView(destination: isFridgeContext ? .fridge : .shopping)
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
        }
        .sheet(isPresented: $showFridgeScan) {
            FridgeScanView()
                .environmentObject(frydgeManager)
        }
        .sheet(isPresented: $showLinkedProduct) {
            if let linkedProduct {
                LinkedProductSheet(
                    product: linkedProduct,
                    addButtonTitle: isFridgeContext ? "Add to Fridge" : "Add to List",
                    onAdd: { addLinkedProduct($0) }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .alert("Couldn't open link", isPresented: Binding(
            get: { linkResolveError != nil },
            set: { if !$0 { linkResolveError = nil } }
        )) {
            Button("OK", role: .cancel) { linkResolveError = nil }
        } message: {
            Text(linkResolveError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                resetView()
                dismiss()
            }
            .foregroundColor(.secondary)

            Spacer()

            if let image = recipeImage {
                HStack(spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(recipeTitle ?? "Add Ingredient")
                        .font(.headline)
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: 2) {
                    Text("Add to \(destinationTitle)").font(.headline)
                    if isQuickAddContext, addedCount > 0 {
                        Text("\(addedCount) added this session")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Fridge and shopping-list contexts are a multi-add loop: every
            // item is saved the moment it's added, so "Done" simply ends the
            // session. Elsewhere the button stays "Close" — there a bold "Done"
            // reads as Save, and people lost typed items to it.
            Button(isQuickAddContext ? "Done" : "Close") {
                dismiss()
            }
            .fontWeight(isQuickAddContext ? .semibold : .regular)
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Type a name, paste a link, or scan…", text: $ingredientName)
                    .focused($focusedField, equals: .item)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit { runSearch() }

                if isCheckingAvailability {
                    ProgressView().scaleEffect(0.75)
                } else if !ingredientName.isEmpty {
                    Button(action: { ingredientName = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Explicit search button — no more auto-search on every keystroke
            let canSearch = !ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: { runSearch() }) {
                Text("Search")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 46)
                    .padding(.horizontal, 14)
                    .background(canSearch ? Color.blue : Color.gray.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSearch)

            Button(action: { showScanner = true }) {
                Image(systemName: "barcode.viewfinder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(availabilityProductCandidates.prefix(10))) { candidate in
                    candidateCard(candidate)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Empty / Loading states

    private var emptySearchPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cart.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            VStack(spacing: 8) {
                Text("Find a product")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Type a product name above or scan a barcode to search for items and pricing across stores.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if isQuickAddContext {
                // Bulk routes: a till receipt or a written list, each with its
                // own review wizard before anything lands in the fridge or on
                // the shopping list. Offered in both quick-add contexts so the
                // fridge and shopping list add sheets match.
                HStack(spacing: 12) {
                    bulkScanButton("Scan Receipt", systemImage: "doc.text.viewfinder") {
                        showReceiptScan = true
                    }
                    bulkScanButton("Scan a List", systemImage: "list.bullet.rectangle") {
                        showListScan = true
                    }
                    // Scanning the fridge's actual contents only makes sense when
                    // adding to the fridge itself, not a shopping list.
                    if isFridgeContext {
                        bulkScanButton("Scan Fridge", systemImage: "refrigerator") {
                            showFridgeScan = true
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            Spacer()
        }
    }

    private func bulkScanButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .foregroundStyle(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.2)
            Text("Searching stores…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            VStack(spacing: 8) {
                Text("No products found")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try a different search term or scan the barcode directly. You can still add it by hand below.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    /// Shown when the lookup itself failed — offline, or the price server is
    /// down. Distinct from "we looked and there's nothing".
    private func searchErrorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(.quaternary)
            VStack(spacing: 8) {
                Text("Couldn't check the stores")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                runSearch()
            } label: {
                Text("Try again")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Candidate Card

    @ViewBuilder
    private func candidateCard(_ candidate: AvailabilityProductCandidate) -> some View {
        let offers = availabilityOffersByCandidateID[candidate.id] ?? []
        let isLoadingPrices = loadingAvailabilityCandidateIDs.contains(candidate.id)
        let isSavedToList = savedAvailabilityCandidateIDs.contains(candidate.id)
        let tags = candidateDietaryTags[candidate.id] ?? detectDietaryTags(for: candidate)
        let (qty, qUnit) = parsedQuantityAndUnit(from: candidate.detailsText, candidate.name)
        let quantityLabel: String? = qty.isEmpty ? nil : "\(qty)\(qUnit)"

        let sizeText: String? = {
            // Prefer the original details text only when it actually mentions a quantity
            // (e.g. "1.5L pack" — richer than just "1.5L"). Otherwise fall back to whatever
            // quantity we parsed out of the name.
            if let details = candidate.detailsText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !details.isEmpty,
               !parsedQuantityAndUnit(from: details).quantity.isEmpty {
                return details
            }
            return quantityLabel
        }()

        VStack(alignment: .leading, spacing: 0) {
            // Product info row — tap to open a preview
            Button {
                openPreview(for: candidate)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    candidateThumbnail(for: candidate)
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if let sizeText {
                            Text(sizeText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Dietary chips
            HStack(spacing: 6) {
                ForEach(["GF", "DF", "V"], id: \.self) { tag in
                    dietaryChip(tag, for: candidate, selectedTags: tags)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)
                .opacity(0.4)

            // Prices — always visible, loading indicator while fetching
            storeOffersSection(candidateOffers: offers, isLoadingCandidate: isLoadingPrices)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 12)
                .opacity(0.4)

            // Save button
            Button {
                if isFridgeContext {
                    saveCandidateToFridge(candidate)
                } else {
                    saveCandidateToShoppingList(candidate)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSavedToList ? "checkmark.circle.fill" : (isFridgeContext ? "plus.circle.fill" : "cart.badge.plus"))
                        .font(.subheadline)
                    Text(isSavedToList
                         ? (isFridgeContext ? "Added to Fridge" : "Added to Shopping List")
                         : (isFridgeContext ? "Add to Fridge" : "Add to Shopping List"))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSavedToList ? Color.green : Color.blue)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: isSavedToList)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Dietary chip (per candidate)

    private func dietaryChip(_ tag: String, for candidate: AvailabilityProductCandidate, selectedTags: Set<String>) -> some View {
        let isSelected = selectedTags.contains(tag)
        let color: Color = tag == "GF" ? .green : tag == "DF" ? .orange : .teal
        return Button {
            var tags = candidateDietaryTags[candidate.id] ?? detectDietaryTags(for: candidate)
            if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
            candidateDietaryTags[candidate.id] = tags
        } label: {
            Text(tag)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color.opacity(0.15) : Color(UIColor.tertiarySystemGroupedBackground))
                .foregroundStyle(isSelected ? color : Color.secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Quick Save Bar (manual fallback when no results)

    private var quickSaveBar: some View {
        VStack(spacing: 10) {
            LinearGradient(
                colors: [Color.appBackground.opacity(0), Color.appBackground],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 20)
            .allowsHitTesting(false)

            if isQuickAddContext {
                quickAttributesRow
                    .padding(.horizontal)
                quickDietaryRow
                    .padding(.horizontal)
            }

            Button(action: saveManualEntry) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text(isQuickAddContext
                         ? "Add \(quickQty) \(selectedUnit) of \"\(ingredientName)\""
                         : "Add \"\(ingredientName)\" to List")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color.appBackground)
    }

    /// Compact quantity + unit + location controls so a fridge add lands with
    /// real values in one tap instead of always defaulting to "1 ea".
    private var quickAttributesRow: some View {
        HStack(spacing: 10) {
            // Quantity stepper
            HStack(spacing: 10) {
                Button { quickQty = max(1, quickQty - 1) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(quickQty <= 1 ? .gray.opacity(0.4) : .blue)
                }
                .buttonStyle(.plain)
                .disabled(quickQty <= 1)

                Text("\(quickQty)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(minWidth: 20)

                Button { quickQty = min(999, quickQty + 1) } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))

            // Unit
            Menu {
                ForEach(quickUnits, id: \.self) { u in
                    Button(u) { selectedUnit = u }
                }
            } label: {
                quickPill(text: selectedUnit.isEmpty ? "ea" : selectedUnit, systemImage: "scalemass")
            }

            // Storage location and best-before only make sense once the item
            // is physically in the fridge; the shopping list keeps just the
            // quantity and unit.
            if isFridgeContext {
            // Location
            Menu {
                ForEach(quickLocations, id: \.self) { loc in
                    Button {
                        applyLocation(loc)
                    } label: {
                        Label(loc, systemImage: locationIcon(for: loc))
                    }
                }
            } label: {
                quickPill(text: locationTag.isEmpty ? "Fridge" : locationTag,
                          systemImage: locationIcon(for: locationTag.isEmpty ? "Fridge" : locationTag))
            }

            // Best before — so a printed date can be entered while adding,
            // rather than only by reopening the item afterwards.
            Button {
                showBBFPicker = true
            } label: {
                quickPill(text: bbfPillText, systemImage: "calendar")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showBBFPicker) {
                VStack(spacing: 14) {
                    DatePicker(
                        "Best before",
                        selection: Binding(
                            get: { expirationDate },
                            set: { newValue in
                                expirationDate = newValue
                                didSetExpiryManually = true
                            }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()

                    if didSetExpiryManually {
                        Button("Use the suggested date") {
                            didSetExpiryManually = false
                            showBBFPicker = false
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .frame(minWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
            } // isFridgeContext

            Spacer(minLength: 0)
        }
    }

    /// Label for the best-before pill: the chosen date, or "Auto" while the
    /// food-type default is still in charge.
    private var bbfPillText: String {
        guard didSetExpiryManually else { return "Auto" }
        return expirationDate.formatted(.dateTime.day().month(.abbreviated))
    }

    /// GF / DF / V toggles for the quick add, so tags can be set while adding
    /// rather than only by editing the item afterwards.
    private var quickDietaryRow: some View {
        HStack(spacing: 10) {
            ForEach(["GF", "DF", "V"], id: \.self) { tag in
                let isOn = dietaryTags.contains(tag)
                Button {
                    if isOn { dietaryTags.remove(tag) } else { dietaryTags.insert(tag) }
                } label: {
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isOn ? .green : .secondary)
                        .frame(width: 38, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isOn ? Color.green.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isOn ? Color.green : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dietaryAccessibilityLabel(tag))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }

            Spacer(minLength: 0)
        }
    }

    private func dietaryAccessibilityLabel(_ tag: String) -> String {
        switch tag {
        case "GF": return "Gluten free"
        case "DF": return "Dairy free"
        case "V":  return "Vegetarian"
        default:   return tag
        }
    }

    private func quickPill(text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption)
            Text(text).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func storeOffersSection(candidateOffers: [StockAvailability.StoreOffer], isLoadingCandidate: Bool) -> some View {
        VStack(spacing: 4) {
            if candidateOffers.isEmpty, isLoadingCandidate {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading prices…").font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if candidateOffers.isEmpty {
                Text("No prices found.").font(.caption).foregroundColor(.secondary).padding(.vertical, 2)
            } else {
                ForEach(Array(candidateOffers.prefix(5))) { offer in
                    HStack(spacing: 10) {
                        storeLogo(for: offer.store)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(offer.store).font(.caption).fontWeight(.semibold)
                        Spacer()
                        if let price = offer.price {
                            Text(formatPrice(price, currencyCode: offer.currencyCode))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        } else {
                            Text("Check store").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Result Preview

    private func openPreview(for candidate: AvailabilityProductCandidate) {
        dismissKeyboard()
        previewProduct = nil
        previewCandidate = candidate
    }

    @ViewBuilder
    private func candidatePreviewSheet(for candidate: AvailabilityProductCandidate) -> some View {
        let offers = availabilityOffersByCandidateID[candidate.id] ?? []
        let isLoadingPrices = loadingAvailabilityCandidateIDs.contains(candidate.id)
        let isSavedToList = savedAvailabilityCandidateIDs.contains(candidate.id)
        let tags = (candidateDietaryTags[candidate.id] ?? detectDietaryTags(for: candidate)).sorted()
        let sizeText = candidate.detailsText?.trimmingCharacters(in: .whitespacesAndNewlines)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack(alignment: .top, spacing: 14) {
                        candidateThumbnail(for: candidate)
                            .frame(width: 84, height: 84)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.displayName)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            if let brand = previewFacts?.brand, !brand.isEmpty,
                               !candidate.displayName.localizedCaseInsensitiveContains(brand) {
                                Text(brand)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let sizeText, !sizeText.isEmpty {
                                Text(sizeText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if !tags.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color(UIColor.tertiarySystemGroupedBackground))
                                            .foregroundStyle(.secondary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }

                    Divider()

                    // Nutrition and product facts lead — the same component the
                    // fridge item sheet and the scanned-product sheet use.
                    ProductNutritionCard(facts: previewFacts, isLoading: isLoadingPreview, productName: candidate.displayName)

                    Divider()

                    // Store prices come last; they're already visible on the result card.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prices")
                            .font(.headline)
                        storeOffersSection(candidateOffers: offers, isLoadingCandidate: isLoadingPrices)
                    }

                    // Add button
                    Button {
                        if isFridgeContext {
                            saveCandidateToFridge(candidate)
                        } else {
                            saveCandidateToShoppingList(candidate)
                        }
                        previewCandidate = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSavedToList ? "checkmark.circle.fill" : (isFridgeContext ? "plus.circle.fill" : "cart.badge.plus"))
                            Text(isSavedToList
                                 ? (isFridgeContext ? "Added to Fridge" : "Added to Shopping List")
                                 : (isFridgeContext ? "Add to Fridge" : "Add to Shopping List"))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { previewCandidate = nil }
                }
            }
            .task(id: candidate.id) {
                previewFacts = nil
                isLoadingPreview = true
                let facts = await ProductNutritionFacts.lookup(name: candidate.displayName)
                guard previewCandidate?.id == candidate.id else { return }
                previewFacts = facts
                isLoadingPreview = false
                // A product image found here also fills in the result card.
                if candidate.imageURL == nil, candidateImageOverrides[candidate.id] == nil, let url = facts?.imageURL {
                    candidateImageOverrides[candidate.id] = url
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { dismissKeyboard() }
                .tint(.blue).font(.headline)
        }
    }

    // MARK: - New helpers

    private func detectDietaryTags(for candidate: AvailabilityProductCandidate) -> Set<String> {
        let text = ([candidate.name, candidate.detailsText].compactMap { $0 }.joined(separator: " ")).lowercased()
        var tags = Set<String>()
        if text.contains("gluten free") || text.contains("gluten-free") || text.contains("(gf)") { tags.insert("GF") }
        if text.contains("dairy free") || text.contains("dairy-free") || text.contains("lactose free") || text.contains("(df)") { tags.insert("DF") }
        if text.contains("vegan") || text.contains("plant-based") || text.contains("plant based") { tags.insert("V") }
        return tags
    }

    private func runSearch() {
        let trimmed = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchDebounceTask?.cancel()
        focusedField = nil

        // A pasted link → resolve it to a real product + nutrition instead of
        // treating the whole URL as a search term.
        if let url = detectedURL(in: trimmed) {
            clearAvailabilityResults()
            Task { await resolveLink(url) }
            return
        }

        clearAvailabilityResults()
        hasSearched = true
        searchError = nil
        fetchAvailabilityProductCandidates(name: trimmed, quantity: "", unit: "")
    }

    // MARK: - Paste-a-link resolution

    /// A URL if the text is (or contains) a http/https link, else nil.
    private func detectedURL(in text: String) -> URL? {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        // Take the first whitespace-delimited token so trailing text is ignored.
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? text
        return URL(string: token)
    }

    /// Pull an 8–14 digit product barcode from a URL's path or query.
    private func barcode(from url: URL) -> String? {
        let digitsOnly: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        // Path components first (Open Food Facts uses /product/<code>/…).
        for comp in url.pathComponents where digitsOnly(comp) && (8...14).contains(comp.count) {
            return comp
        }
        // Then any query value.
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                if let v = item.value, digitsOnly(v), (8...14).contains(v.count) { return v }
            }
        }
        return nil
    }

    private func firstBarcode(inHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d{8,14}\b"#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let r = Range(match.range, in: html) else { return nil }
        return String(html[r])
    }

    @MainActor
    private func resolveLink(_ url: URL) async {
        isResolvingLink = true
        linkResolveError = nil
        defer { isResolvingLink = false }

        // 1. Barcode straight from the URL (Open Food Facts and most product pages).
        if let code = barcode(from: url), let product = try? await OpenFoodFactsService.shared.fetchByBarcode(code) {
            presentLinkedProduct(product)
            return
        }

        // 2. Otherwise fetch the page: look for a barcode in the HTML, then fall
        //    back to the page title as a plain-text search.
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (compatible; FrydgeBot/1.0)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(decoding: data, as: UTF8.self)

            if let code = firstBarcode(inHTML: html),
               let product = try? await OpenFoodFactsService.shared.fetchByBarcode(code) {
                presentLinkedProduct(product)
                return
            }

            if let title = pageTitle(fromHTML: html) {
                ingredientName = title
                fetchAvailabilityProductCandidates(name: title, quantity: "", unit: "")
                return
            }
        } catch {
            // fall through to error
        }

        linkResolveError = "Couldn't read a product from that link. Try the product name instead."
    }

    private func pageTitle(fromHTML html: String) -> String? {
        // Prefer Open Graph title, fall back to <title>.
        if let og = firstMatch(in: html, pattern: #"<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)[\"']"#) {
            return cleanTitle(og)
        }
        if let title = firstMatch(in: html, pattern: #"<title[^>]*>([^<]+)</title>"#) {
            return cleanTitle(title)
        }
        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func cleanTitle(_ raw: String) -> String {
        // Strip common "| Store Name" suffixes and decode a couple of entities.
        let base = raw.components(separatedBy: CharacterSet(charactersIn: "|–-")).first ?? raw
        return base
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentLinkedProduct(_ product: OFFProduct) {
        linkedProduct = product
        showLinkedProduct = true
        if let name = product.productName, !name.isEmpty, name.caseInsensitiveCompare("Unknown") != .orderedSame {
            ingredientName = name
        }
    }

    private func addLinkedProduct(_ product: OFFProduct) {
        let name = (product.productName?.isEmpty == false ? product.productName! : ingredientName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let (num, unit) = OFFProduct.parseQuantityAndUnit(from: product.quantity ?? "")
        let qty = num.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "1"
        let resolvedUnit = (unit?.isEmpty == false) ? unit! : "ea"

        if isFridgeContext {
            frydgeManager.addAutoClassifiedProduct(
                name: name,
                quantity: qty,
                unit: resolvedUnit
            )
            showLinkedProduct = false
            completeQuickAdd(named: name)
            return
        }

        shoppingListManager.addToShoppingList(
            name: name,
            quantity: qty,
            unit: resolvedUnit,
            location: "Shopping",
            dietaryTags: []
        )

        showLinkedProduct = false
        if isShoppingContext {
            completeQuickAdd(named: name)
            return
        }
        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isShowing = false }
    }

    // MARK: - Multi-add loop (fridge + personal shopping list)

    /// Called after every successful quick add. Confirms with a toast and
    /// returns the sheet to its ready state — empty search, scanner and
    /// keyboard available — so the next item can go straight in. The sheet
    /// only closes when the user taps Done.
    private func completeQuickAdd(named name: String) {
        noteQuickAdd(named: name)
        resetForNextItem()
    }

    /// Counts and confirms an add without touching the current search, so
    /// several results can be added from one list before it resets.
    private func noteQuickAdd(named name: String) {
        addedCount += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showAddedToast("Added \(name)")
    }

    /// Back to the ready state for the next item.
    private func resetForNextItem() {
        ingredientName = ""
        quantity = ""
        quickQty = 1
        selectedUnit = "ea"
        customUnit = ""
        showCustomUnitField = false
        locationTag = ""
        dietaryTags = []
        didSetExpiryManually = false
        expirationDate = Date()
        productDetails = nil
        scannedProductDetails = nil
        scannedBarcode = ""
        linkedProduct = nil
        isSaved = false
        clearAvailabilityResults()
        candidateImageOverrides = [:]
        focusedField = .item
    }

    private func showAddedToast(_ text: String) {
        addedToastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { addedToast = text }
        addedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { addedToast = nil }
        }
    }

    private func triggerDebouncedSearch(for text: String) {
        searchDebounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .seconds(0.65))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                fetchAvailabilityProductCandidates(name: trimmed, quantity: "", unit: "")
            }
        }
    }

    private func saveManualEntry() {
        let name = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let qty = String(max(1, quickQty))
        let unit = selectedUnit.isEmpty ? "ea" : selectedUnit

        // Hosts with their own save handler (shared lists, item edit sheet,
        // recipe editor) receive the entry through that handler; previously
        // the quick bar wrote straight to the personal shopping list no matter
        // who presented the sheet.
        if hasCustomSaveHandler {
            quantity = qty
            selectedUnit = unit
            showCustomUnitField = false
            saveProductDetails()
            return
        }

        if isFridgeContext {
            let loc = locationTag.isEmpty ? "Fridge" : locationTag
            // A date the user typed always wins. Otherwise freezer/pantry get a
            // location-based shelf life and fridge uses the food-type default,
            // so perishables still expire sensibly.
            let expiry: Date
            if didSetExpiryManually {
                expiry = expirationDate
            } else {
                expiry = loc == "Fridge" ? defaultExpiryForFood(named: name) : defaultExpiryDate(for: loc)
            }
            frydgeManager.addProduct(
                name: name,
                quantity: qty,
                unit: unit,
                expirationDate: expiry,
                location: loc,
                dietaryTags: dietaryTags,
                lifecycle: .fridge
            )
            completeQuickAdd(named: name)
            return
        }

        shoppingListManager.addToShoppingList(
            name: name,
            quantity: qty,
            unit: unit,
            location: "Shopping",
            dietaryTags: dietaryTags
        )

        // Personal shopping list behaves like the fridge: confirm, reset, and
        // stay open for the next item.
        if isShoppingContext {
            completeQuickAdd(named: name)
            return
        }

        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isShowing = false
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
    }

    private func clearAvailabilityResults() {
        availabilityProductCandidates = []
        availabilityOffersByCandidateID = [:]
        loadingAvailabilityCandidateIDs = []
        savedAvailabilityCandidateIDs = []
        candidateDietaryTags = [:]
        hasSearched = false
        searchError = nil
    }

    private func applyDetectedItemName(_ detectedName: String) {
        let trimmed = detectedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let current = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current.caseInsensitiveCompare("Unknown") == .orderedSame {
            ingredientName = trimmed
            clearAvailabilityResults()
        }
    }

    private func applyLocation(_ loc: String) {
        locationTag = loc
        expirationDate = defaultExpiryDate(for: loc)
    }

    private func defaultExpiryDate(for loc: String) -> Date {
        let now = Date()
        switch loc {
        case "Fridge":
            return Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        case "Freezer":
            return Calendar.current.date(byAdding: .day, value: 365, to: now) ?? now
        default:
            return Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        }
    }

    private func defaultExpiryForFood(named name: String) -> Date {
        StoredIngredient.defaultExpiry(for: name)
    }

    private func locationIcon(for loc: String) -> String {
        switch loc {
        case "Fridge": return "drop.fill"
        case "Freezer": return "snowflake"
        case "Dry": return "cabinet.fill"
        case "Shopping": return "cart"
        default: return "questionmark"
        }
    }

    // MARK: - Existing logic

    private func handleOnAppear() {
        if let details = productDetails {
            ingredientName = (details.productName?.isEmpty == false && details.productName != "Unknown")
                ? (details.productName ?? "")
                : ""

            applyQuantityAndUnit(from: details)
        }

        if autoStartScanner, !didAutoStartScanner {
            didAutoStartScanner = true
            DispatchQueue.main.async {
                showScanner = true
            }
        }
    }

    private func handleScannedProductDetails() {
        if let details = scannedProductDetails {
            let scannedName = (details.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            if !scannedName.isEmpty, scannedName.caseInsensitiveCompare("Unknown") != .orderedSame {
                ingredientName = scannedName
            }

            applyQuantityAndUnit(from: details)
            productDetails = details

            // Scanning is an explicit intent — auto-search without requiring a tap
            let nameToSearch = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nameToSearch.isEmpty {
                clearAvailabilityResults()
                fetchAvailabilityProductCandidates(name: nameToSearch, quantity: "", unit: "")
            }

            // A barcode hit is a known product: open its detail (nutrition first,
            // one-tap add) straight away — the same sheet a pasted link opens —
            // while the store search fills in behind it.
            if let known = details as? OFFProduct,
               known.code?.isEmpty == false,
               !nameToSearch.isEmpty {
                presentLinkedProduct(known)
            }
        }
    }

    private static let knownUnits = ["ml", "l", "g", "kg", "lb", "ea", "bars", "cans", "herb", "seasoning", "bottles"]

    private func applyQuantityAndUnit(from details: ProductProtocol) {
        if let offProduct = details as? OFFProduct, let raw = offProduct.quantity {
            let (num, unit) = OFFProduct.parseQuantityAndUnit(from: raw)
            if let num, num > 0 {
                quantity = num.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(num))
                    : String(num)
            } else {
                quantity = ""
            }
            if let unit, !unit.isEmpty {
                applyUnitToPicker(unit)
            }
            return
        }

        if let value = details.quantityValue, value > 0 {
            quantity = String(value)
        } else {
            quantity = ""
        }
    }

    private func applyUnitToPicker(_ unit: String) {
        let lower = unit.lowercased()
        if Self.knownUnits.contains(lower) {
            selectedUnit = lower
            showCustomUnitField = false
            customUnit = ""
        } else {
            selectedUnit = "other"
            showCustomUnitField = true
            customUnit = unit
        }
    }

    private func availabilityQuery(name: String, quantity: String, unit: String) -> String {
        [name, quantity, unit]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @ViewBuilder
    private func candidateThumbnail(for candidate: AvailabilityProductCandidate) -> some View {
        let fallback = ZStack {
            Color(.systemGray6)
            Text(FoodEmoji.emoji(for: candidate.name))
                .font(.title3)
        }
        if let url = candidate.imageURL ?? candidateImageOverrides[candidate.id] {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private func fetchAvailabilityProductCandidates(name: String, quantity: String, unit: String) {
        let query = availabilityQuery(name: name, quantity: quantity, unit: unit)
        guard !query.isEmpty else { return }

        availabilityProductCandidates = []
        availabilityOffersByCandidateID = [:]
        loadingAvailabilityCandidateIDs = []
        savedAvailabilityCandidateIDs = []
        candidateDietaryTags = [:]
        isCheckingAvailability = true
        focusedField = nil

        Task {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://grocery-price-server.davekitson-read.workers.dev/search-products?q=\(encoded)&limit=10") else {
                await MainActor.run {
                    self.isCheckingAvailability = false
                    self.searchError = "That search term couldn't be used. Try simpler wording."
                }
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    await MainActor.run {
                        self.isCheckingAvailability = false
                        self.searchError = "The price server didn't respond properly. It may be busy — try again in a moment."
                    }
                    return
                }

                let decoded = try JSONDecoder().decode(AvailabilityProductSearchResponse.self, from: data)
                let allMapped = decoded.products.map {
                    AvailabilityProductCandidate(
                        name: $0.name,
                        detailsText: $0.detailsText,
                        imageURL: URL(string: $0.imageUrl ?? ""),
                        productURL: URL(string: $0.productUrl ?? ""),
                        productID: $0.productID,
                        sourceStore: $0.chain
                    )
                }

                // Collapse the same product listed by several chains (or twice by
                // one) into a single result. The key tolerates each chain's
                // spelling ("Sun-Maid" / "Sunmaid", dropped descriptors, word
                // order) but keeps sizes apart, so "Best Foods Mayonnaise 400g"
                // from three chains is one row while 800g is another. When
                // duplicates differ, the richer listing (photo, details, fuller
                // name) represents the group.
                var byKey: [String: Int] = [:]
                var mapped: [AvailabilityProductCandidate] = []
                for candidate in allMapped {
                    let key = candidate.dedupeKey
                    if let index = byKey[key] {
                        if candidate.isRicher(than: mapped[index]) {
                            mapped[index] = candidate
                        }
                    } else {
                        byKey[key] = mapped.count
                        mapped.append(candidate)
                    }
                }

                await MainActor.run {
                    self.availabilityProductCandidates = mapped
                    self.isCheckingAvailability = false
                    self.focusedField = nil

                    // Pre-populate dietary tags so chips light up immediately
                    for candidate in mapped {
                        let detected = self.detectDietaryTags(for: candidate)
                        self.candidateDietaryTags[candidate.id] = detected
                    }
                }

                // Preload prices in the background for all results
                for candidate in mapped {
                    self.fetchStorePrices(for: candidate)
                }

                // Fill in missing product images from the products DB.
                self.fetchMissingImages(for: mapped.filter { $0.imageURL == nil })
            } catch {
                await MainActor.run {
                    self.availabilityProductCandidates = []
                    self.availabilityOffersByCandidateID = [:]
                    self.loadingAvailabilityCandidateIDs = []
                    self.isCheckingAvailability = false
                    self.focusedField = nil
                    self.searchError = (error as? URLError)?.code == .notConnectedToInternet
                        ? "You're offline. Connect and try again, or add the item by hand below."
                        : "Couldn't reach the price server. Check your connection and try again."
                }
            }
        }
    }

    /// Looks up a product image for results the price server returned without
    /// one. Runs sequentially in the background so a 10-result search doesn't
    /// fire 10 simultaneous requests; rows update as images arrive.
    private func fetchMissingImages(for candidates: [AvailabilityProductCandidate]) {
        guard !candidates.isEmpty else { return }
        let targets = Array(candidates.prefix(10))
        Task {
            for candidate in targets {
                // Stop if the results have been replaced by a new search.
                let stillShown = await MainActor.run { availabilityProductCandidates.contains { $0.id == candidate.id } }
                guard stillShown else { return }
                guard let rich = try? await OpenFoodFactsService.shared.searchRich(candidate.displayName).first,
                      let urlString = rich.imageSmallURL ?? rich.imageURL,
                      let url = URL(string: urlString) else { continue }
                await MainActor.run {
                    if candidateImageOverrides[candidate.id] == nil {
                        candidateImageOverrides[candidate.id] = url
                    }
                }
            }
        }
    }

    private func fetchStorePrices(for candidate: AvailabilityProductCandidate) {
        loadingAvailabilityCandidateIDs.insert(candidate.id)

        let query = [candidate.name, candidate.detailsText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        Task {
            let offers = await StockAvailability.fetchOffers(for: query)
            let filtered = offers.filter { $0.store != "Search" }

            var bestByChain: [String: StockAvailability.StoreOffer] = [:]
            for offer in filtered {
                let key = offer.store.lowercased()
                if let existing = bestByChain[key] {
                    if let newPrice = offer.price, let oldPrice = existing.price, newPrice < oldPrice {
                        bestByChain[key] = offer
                    }
                } else {
                    bestByChain[key] = offer
                }
            }
            let deduped = bestByChain.values.sorted {
                switch ($0.price, $1.price) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.store < $1.store
                }
            }

            await MainActor.run {
                self.availabilityOffersByCandidateID[candidate.id] = deduped
                self.loadingAvailabilityCandidateIDs.remove(candidate.id)
                self.focusedField = nil
            }
        }
    }

    private func saveCandidateToShoppingList(_ candidate: AvailabilityProductCandidate) {
        guard !savedAvailabilityCandidateIDs.contains(candidate.id) else { return }

        let parsed = parsedQuantityAndUnit(from: candidate.detailsText, candidate.name)
        let tags = candidateDietaryTags[candidate.id] ?? detectDietaryTags(for: candidate)

        shoppingListManager.addToShoppingList(
            name: candidate.name,
            quantity: parsed.quantity.isEmpty ? "1" : parsed.quantity,
            unit: parsed.unit.isEmpty ? "ea" : parsed.unit,
            location: "Shopping",
            dietaryTags: tags
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            _ = savedAvailabilityCandidateIDs.insert(candidate.id)
        }

        isSaved = true

        guard isShoppingContext else {
            // Shared lists keep the old behaviour: leave the result marked
            // and let the user close the sheet themselves.
            ingredientName = candidate.name
            if !parsed.quantity.isEmpty { quantity = parsed.quantity }
            if !parsed.unit.isEmpty { applyUnitToPicker(parsed.unit) }
            return
        }

        // Same loop as the fridge: confirm with a toast, then return to the
        // ready state for the next item.
        noteQuickAdd(named: candidate.displayName)
        let savedID = candidate.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard savedAvailabilityCandidateIDs.contains(savedID) else { return }
            resetForNextItem()
        }
    }

    private func saveCandidateToFridge(_ candidate: AvailabilityProductCandidate) {
        guard !savedAvailabilityCandidateIDs.contains(candidate.id) else { return }

        let parsed = parsedQuantityAndUnit(from: candidate.detailsText, candidate.name)
        let tags = candidateDietaryTags[candidate.id] ?? detectDietaryTags(for: candidate)

        frydgeManager.addAutoClassifiedProduct(
            name: candidate.name,
            quantity: parsed.quantity.isEmpty ? "1" : parsed.quantity,
            unit: parsed.unit.isEmpty ? "ea" : parsed.unit,
            dietaryTags: tags
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            _ = savedAvailabilityCandidateIDs.insert(candidate.id)
        }
        noteQuickAdd(named: candidate.displayName)

        // Let the "Added" state show briefly, then return to search/scan for
        // the next item. Skipped if the results have already been reset
        // (a quick second add, or a new search) so nothing is cleared twice.
        let savedID = candidate.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard savedAvailabilityCandidateIDs.contains(savedID) else { return }
            resetForNextItem()
        }
    }

    private func parsedQuantityAndUnit(from sources: String?...) -> (quantity: String, unit: String) {
        // Match <number><known-unit>, where the unit is not followed by another letter
        // (so "g" in "grain" doesn't match). Long forms listed before short ones so the
        // alternation prefers the longest match (e.g. "kg" over "g", "ml" over "l").
        let pattern = #"(?i)(\d+(?:[.,]\d+)?)\s*(kilograms?|kilos?|kg|grams?|mg|millilitres?|milliliters?|ml|centilitres?|centiliters?|cl|litres?|liters?|fl\s*oz|oz|lb|lbs|packs?|pk|pkt|each|ea|dozen|doz|l|g)(?![a-zA-Z])"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ("", "") }

        for source in sources {
            guard let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }

            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: nsRange),
                  match.numberOfRanges >= 3,
                  let qtyRange = Range(match.range(at: 1), in: raw),
                  let unitRange = Range(match.range(at: 2), in: raw) else {
                continue
            }

            let quantity = String(raw[qtyRange])
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = normalizedUnit(String(raw[unitRange]))
            return (quantity, unit)
        }

        return ("", "")
    }

    private func normalizedUnit(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "kilogram", "kilograms", "kilo", "kilos": return "kg"
        case "gram", "grams":                          return "g"
        case "millilitre", "millilitres",
             "milliliter", "milliliters":              return "ml"
        case "centilitre", "centilitres",
             "centiliter", "centiliters":              return "cl"
        case "litre", "litres", "liter", "liters":     return "L"
        case "fl oz", "floz":                          return "fl oz"
        case "pound", "pounds", "lbs":                 return "lb"
        case "pack", "packs", "pk", "pkt":             return "pk"
        case "each", "ea":                             return "ea"
        case "dozen", "doz":                           return "dz"
        case "l":                                      return "L"
        default:                                       return lower
        }
    }

    private func formatPrice(_ price: Double, currencyCode: String) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currencyCode
        nf.maximumFractionDigits = 2
        nf.minimumFractionDigits = 0
        return nf.string(from: NSNumber(value: price)) ?? "\(price)"
    }

    @ViewBuilder
    private func storeLogo(for store: String) -> some View {
        let lower = store.lowercased()
        if lower.contains("woolworth") {
            Image("woolworths").resizable().scaledToFit()
        } else if lower.contains("pak") && lower.contains("save") {
            Image("paknsave").resizable().scaledToFit()
        } else if lower.contains("new world") {
            Image("newworld").resizable().scaledToFit()
        } else {
            Image(systemName: "cart")
                .resizable().scaledToFit().foregroundColor(.secondary).padding(10)
        }
    }

    private func saveProductDetails() {
        let unit = showCustomUnitField ? customUnit : selectedUnit
        let formattedDate = DateFormatter.localizedString(from: expirationDate, dateStyle: .medium, timeStyle: .none)

        let isAnyShoppingContext: Bool = {
            if case .shopping = context { return true }
            if case .sharedShopping = context { return true }
            return false
        }()

        let chosenLocation = locationTag.isEmpty ? (isAnyShoppingContext ? "Shopping" : "Dry") : locationTag
        let expiryToUse = expirationDate

        let name = ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let qtyRaw = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalQty = qtyRaw.isEmpty ? "1" : qtyRaw
        let tags = dietaryTags

        let formatted: String = {
            if finalQty.isEmpty { return name }
            return "\(name) \(finalQty)\(unit)".trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        if let onConfirmStructured {
            onConfirmStructured(name, finalQty, unit)
            isSaved = true
            isShowing = false
            return
        }
        if let onConfirm {
            let confirmedProduct = OFFProduct(
                code: nil,
                productName: name,
                ingredientsText: "",
                quantity: finalQty,
                imageUrl: nil,
                nutriments: nil
            )
            onConfirm(confirmedProduct)
            isSaved = true
            isShowing = false
            return
        }
        if let onSaveItem {
            onSaveItem(formatted)
            onSaveStructuredItem?(name, finalQty, unit, chosenLocation, Array(tags))
            isSaved = true
            isShowing = false
            return
        }
        if let onSaveStructuredItem {
            onSaveStructuredItem(name, finalQty, unit, chosenLocation, Array(tags))
            isSaved = true
            isShowing = false
            return
        }

        switch context {
        case .recipe:
            onAddToRecipe?(formatted)

        case .fridge:
            frydgeManager.addProduct(
                name: name,
                quantity: finalQty,
                unit: unit,
                expirationDate: expiryToUse,
                location: chosenLocation,
                dietaryTags: tags,
                lifecycle: .fridge
            )

        case .shopping:
            shoppingListManager.addToShoppingList(
                name: name,
                quantity: finalQty,
                unit: unit,
                location: chosenLocation,
                dietaryTags: tags
            )

        case .sharedFridge(let anchor, let db):
            Task {
                do {
                    try await saveSharedItem(
                        to: db, anchor: anchor, lifecycle: "fridge",
                        name: name, finalQty: finalQty, unit: unit,
                        expiryToUse: expiryToUse, chosenLocation: chosenLocation, tags: tags
                    )
                    await MainActor.run { isSaved = true; isShowing = false }
                } catch {
                    print("[ERROR] saveSharedItem:", error.localizedDescription)
                }
            }
            return

        case .sharedShopping(let anchor, let db):
            Task {
                do {
                    _ = try await saveSharedItem(
                        to: db, anchor: anchor, lifecycle: "shopping",
                        name: name, finalQty: finalQty, unit: unit,
                        expiryToUse: expiryToUse, chosenLocation: chosenLocation, tags: tags
                    )
                    await MainActor.run { isSaved = true; isShowing = false }
                } catch {
                    print("[ERROR] saveSharedItem(sharedShopping):", error.localizedDescription)
                }
            }
            return
        }

        isSaved = true
        _ = formattedDate
        isShowing = false
    }

    @discardableResult
    private func saveSharedItem(
        to db: CKDatabase,
        anchor: CKRecord,
        lifecycle: String,
        name: String,
        finalQty: String,
        unit: String,
        expiryToUse: Date,
        chosenLocation: String,
        tags: Set<String>
    ) async throws -> CKRecord {
        let zoneID = anchor.recordID.zoneID
        let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let rec = CKRecord(recordType: "StoredIngredient", recordID: recID)

        rec.parent = CKRecord.Reference(recordID: anchor.recordID, action: .none)
        rec["fridge"] = CKRecord.Reference(recordID: anchor.recordID, action: .none)
        rec["name"] = name as CKRecordValue
        rec["quantity"] = finalQty as CKRecordValue
        rec["unit"] = unit as CKRecordValue
        rec["expirationDate"] = expiryToUse as CKRecordValue
        rec["location"] = chosenLocation as CKRecordValue
        rec["lifecycle"] = lifecycle as CKRecordValue
        if !tags.isEmpty { rec["dietaryTags"] = Array(tags) as CKRecordValue }

        let savedRecord = try await db.save(rec)
        print("[CK] ✅ Saved shared item '\(name)' in shared zone \(zoneID.zoneName)")

        await MainActor.run {
            scheduleSharedExpiryNotification(for: savedRecord, leadTimeHours: 24)
        }

        return savedRecord
    }

    private func sharedExpiryNotificationID(for record: CKRecord) -> String {
        "shared-exp-" + record.recordID.recordName
    }

    private func scheduleSharedExpiryNotification(for record: CKRecord, leadTimeHours: Int = 24) {
        let name = (record["name"] as? String) ?? "Item"
        let expiry = (record["expirationDate"] as? Date) ?? Date()
        let id = sharedExpiryNotificationID(for: record)

        let target = Calendar.current.date(byAdding: .hour, value: -leadTimeHours, to: expiry) ?? expiry
        let fireDate = max(target, Date().addingTimeInterval(5))

        let content = UNMutableNotificationContent()
        content.title = "Frydge"
        content.body = "\(name) is expiring soon."
        content.sound = .default
        content.userInfo = [
            "ckRecordName": record.recordID.recordName,
            "ckZoneName": record.recordID.zoneID.zoneName,
            "ckOwner": record.recordID.zoneID.ownerName
        ]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { print("[NOTIF] schedule shared expiry failed:", err) }
        }
    }

    private func resetView() {
        ingredientName = ""
        quantity = ""
        customUnit = ""
        expirationDate = Date()
        isSaved = false
        productDetails = nil
        scannedProductDetails = nil
        scannedBarcode = ""
        isCheckingAvailability = false
        availabilityProductCandidates = []
        availabilityOffersByCandidateID = [:]
        loadingAvailabilityCandidateIDs = []
        savedAvailabilityCandidateIDs = []
        candidateDietaryTags = [:]
        hasSearched = false
        searchError = nil
        didSetExpiryManually = false
        dietaryTags = []
        quickQty = 1
        searchDebounceTask?.cancel()
        focusedField = nil
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}


private struct AvailabilityProductCandidate: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let detailsText: String?
    let imageURL: URL?
    let productURL: URL?
    let productID: String?
    let sourceStore: String

    private static let sizePattern = #"(?i)\b(\d+(?:[.,]\d+)?)\s*(kg|g|gm|grams?|ml|l|litres?|liters?|pk|pack|packs)\b"#
    private static let noiseWords: Set<String> = ["the", "and", "with", "of", "a", "an", "in"]

    /// Marketing and format words that chains add or drop at will ("Sun-Maid
    /// Natural California Raisins" vs "Sunmaid Raisins"). Ignored for identity
    /// so the same product and size from three catalogues is one row.
    private static let descriptorWords: Set<String> = [
        "natural", "california", "original", "classic", "premium", "select", "selected",
        "fresh", "pure", "real", "traditional", "finest", "quality", "family", "value",
        "everyday", "essentials", "range", "brand", "nz", "new", "zealand", "australian",
        "pack", "packet", "bag", "box", "tub", "bottle", "jar", "can", "tin", "pouch",
        "each", "ea", "approx", "snack", "snacks"
    ]

    /// Size unit spellings folded to one form so "250 g" and "250gm" agree.
    private static func canonicalUnit(_ unit: String) -> String {
        switch unit.lowercased() {
        case "gm", "gram", "grams": return "g"
        case "litre", "litres", "liter", "liters": return "l"
        case "pack", "packs": return "pk"
        default: return unit.lowercased()
        }
    }

    /// The name without its size, since size is shown on its own line.
    /// Falls back to the full name when stripping would leave nothing useful.
    var displayName: String {
        var s = name
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: Self.sizePattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, "-|,•".contains(last) {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s.count >= 3 ? s : name
    }

    /// Normalised identity, tolerant of how each chain spells a product.
    ///
    /// Two halves: the size ("250g", "1·5l", "6pk") and the product words.
    /// Sizes are compacted and unit spellings unified. Product words have
    /// marketing descriptors and noise dropped, plurals trimmed, and are then
    /// reduced to their sorted letters, which makes the key independent of
    /// spacing, hyphens and word order: "Sun-Maid Raisins", "Sunmaid Raisins"
    /// and "Raisins Sun Maid" all become the same key. Different sizes or
    /// genuinely different products stay distinct.
    var dedupeKey: String {
        var s = name.lowercased().replacingOccurrences(of: "&amp;", with: "&")
        // Keep decimals together ("1.5" → "1·5") so they survive the strip below.
        s = s.replacingOccurrences(of: #"(\d+)[.,](\d+)"#, with: "$1·$2", options: .regularExpression)
        // Apostrophes and hyphens inside a word are spelling, not word breaks.
        s = s.replacingOccurrences(of: #"(?<=[a-z])['’\-](?=[a-z])"#, with: "", options: .regularExpression)

        var sizes = Set<String>()
        func collectSizes(from text: String) {
            guard let regex = try? NSRegularExpression(pattern: Self.sizePattern) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let numRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text) else { continue }
                let number = String(text[numRange]).replacingOccurrences(of: ",", with: "·")
                sizes.insert(number + Self.canonicalUnit(String(text[unitRange])))
            }
        }
        collectSizes(from: s)
        // Strip the sizes out of the name so their digits don't leak into the word half.
        s = s.replacingOccurrences(of: Self.sizePattern, with: " ", options: .regularExpression)

        // If the name carries no size but the details do, fold that in so
        // "Mayonnaise" at 400g and 800g stay distinct.
        if sizes.isEmpty, let details = detailsText?.lowercased() {
            collectSizes(from: details.replacingOccurrences(of: #"(\d+)[.,](\d+)"#, with: "$1·$2", options: .regularExpression))
        }

        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        let words = s.split(separator: " ").map(String.init).filter { word in
            !word.isEmpty && !Self.noiseWords.contains(word) && !Self.descriptorWords.contains(word)
        }
        .map { word -> String in
            // "raisins" / "raisin": one product.
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
        }

        let letters = String(words.joined().sorted())
        return sizes.sorted().joined(separator: " ") + "|" + letters
    }

    /// Of two listings judged to be the same product, which one should
    /// represent it? A photo beats no photo; otherwise the fuller name wins
    /// so the card doesn't end up with the sparsest chain's spelling.
    func isRicher(than other: AvailabilityProductCandidate) -> Bool {
        if (imageURL != nil) != (other.imageURL != nil) { return imageURL != nil }
        let myDetail = (detailsText?.isEmpty == false)
        let otherDetail = (other.detailsText?.isEmpty == false)
        if myDetail != otherDetail { return myDetail }
        return name.count > other.name.count
    }
}

private struct AvailabilityProductSearchResponse: Decodable {
    let products: [AvailabilityProductSearchItem]
}

private struct AvailabilityProductSearchItem: Decodable {
    let name: String
    let detailsText: String?
    let imageUrl: String?
    let productUrl: String?
    let productID: String?
    let chain: String
}

private extension ProductProtocol {
    var primaryImageURL: URL? { nil }
}

// MARK: - Linked product sheet (resolved from a pasted link)

/// Shows the product + nutrition pulled from a pasted link, with a one-tap add.
private struct LinkedProductSheet: View {
    let product: OFFProduct
    let addButtonTitle: String
    let onAdd: (OFFProduct) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Starts from what the barcode/link gave us, then upgrades to the rich
    /// record (scores, saturated fat, sugars, dietary flags) when available.
    @State private var facts: ProductNutritionFacts
    @State private var isLoadingFacts = false

    init(product: OFFProduct, addButtonTitle: String, onAdd: @escaping (OFFProduct) -> Void) {
        self.product = product
        self.addButtonTitle = addButtonTitle
        self.onAdd = onAdd
        _facts = State(initialValue: ProductNutritionFacts(product: product))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    imageHeader

                    Text(product.productName?.isEmpty == false ? product.productName! : "Product")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if let q = product.quantity, !q.isEmpty {
                        Text(q)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ProductNutritionCard(facts: facts, isLoading: isLoadingFacts, productName: product.productName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                }
                .padding(20)
            }
            .task {
                guard let code = product.code, !code.isEmpty else { return }
                isLoadingFacts = true
                if let rich = try? await OpenFoodFactsService.shared.fetchRich(code) {
                    facts = ProductNutritionFacts(product: rich)
                }
                // Fill the ratings the Worker lacks (Green-Score, carbon,
                // additive tags) and recognise additives in the label text.
                facts = await facts.enriched(name: product.productName ?? "", barcode: code)
                isLoadingFacts = false
            }
            .navigationTitle("Found Product")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAdd(product)
                } label: {
                    Text(addButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.blue))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var imageHeader: some View {
        if let urlString = product.imageUrl, let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    placeholder
                }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill)))
        } else {
            placeholder.frame(height: 160).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill)))
        }
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
    }
}
