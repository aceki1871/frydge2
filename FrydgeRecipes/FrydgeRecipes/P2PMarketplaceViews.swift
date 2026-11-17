//
//  P2PMarketplaceViews.swift
//  FrydgeRecipes
//
//  Created on 29/04/2026.
//

import SwiftUI
import PhotosUI
import CoreLocation
import MapKit
import PassKit

// what3words API key — get yours free at https://developer.what3words.com.
// Read from the gitignored `secrets.plist` (key `What3WordsAPIKey`); empty
// when not supplied, which disables the 3-word-address lookup.
private let kW3WApiKey = FrydgeSecrets.what3wordsAPIKey

// MARK: - Add P2P Listing View

struct AddP2PListingView: View {
    @ObservedObject var marketplaceManager: P2PMarketplaceManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var geoManager = GeoLocationManager()
    @ObservedObject private var connect = StripeConnectManager.shared

    @State private var title = ""
    @State private var description = ""
    @State private var price = ""
    @State private var currency = "NZD"
    @State private var sellerName = ""
    @State private var selectedImage: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var what3Words = ""
    @State private var capturedLocation: CLLocationCoordinate2D?
    @State private var isCapturingLocation = false
    @State private var isFetchingW3W = false
    @State private var isCreating = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showPayoutSetup = false

    private var parsedPrice: Decimal? {
        parseDecimal(price)
    }
    
    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !description.trimmingCharacters(in: .whitespaces).isEmpty &&
        (parsedPrice ?? 0) > 0 &&
        !sellerName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("What are you selling?") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    
                    HStack {
                        TextField("Price", text: $price)
                            .keyboardType(.decimalPad)
                        
                        Picker("Currency", selection: $currency) {
                            Text("NZD").tag("NZD")
                            Text("USD").tag("USD")
                            Text("GBP").tag("GBP")
                            Text("EUR").tag("EUR")
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                Section("Photo") {
                    PhotosPicker(selection: $selectedImage, matching: .images) {
                        if let uiImage = UIImage.frydgeBounded(data: imageData, maxPixelSize: ImageBudget.display) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Label("Add a Photo", systemImage: "photo")
                        }
                    }
                    .onChange(of: selectedImage) { _, newValue in
                        Task {
                            if let data = try? await newValue?.loadTransferable(type: Data.self) {
                                imageData = data
                            }
                        }
                    }
                    if imageData != nil {
                        Button("Remove Photo", role: .destructive) {
                            imageData = nil
                            selectedImage = nil
                        }
                    }
                }
                
                Section {
                    TextField("Your Name", text: $sellerName)
                        .textContentType(.name)
                    payoutStatusRow
                } header: {
                    Text("Seller")
                } footer: {
                    Text("Buyers pay with Apple Pay or card through Stripe, or in person with Tap to Pay on your iPhone. Frydge never asks for your bank details.")
                }

                Section {
                    // GPS status row
                    if let loc = capturedLocation {
                        HStack {
                            Image(systemName: "location.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Location captured").font(.subheadline)
                                Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { capturedLocation = nil }
                                .font(.caption)
                        }
                    }

                    // Use My Location — grabs GPS and auto-fills what3words
                    Button {
                        captureLocationAndFetchW3W()
                    } label: {
                        if isCapturingLocation {
                            HStack { ProgressView().scaleEffect(0.85); Text("Getting location…") }
                        } else if isFetchingW3W {
                            HStack { ProgressView().scaleEffect(0.85); Text("Looking up what3words…") }
                        } else {
                            Label(
                                capturedLocation == nil ? "Use My Location" : "Update Location",
                                systemImage: "location.circle.fill"
                            )
                        }
                    }
                    .disabled(isCapturingLocation || isFetchingW3W)

                    // Manual what3words field
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.blue)
                        TextField("e.g. filled.count.soap", text: $what3Words)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    if !what3Words.isEmpty {
                        Button {
                            let words = what3Words.trimmingCharacters(in: .whitespacesAndNewlines)
                            let encoded = words.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? words
                            if let url = URL(string: "https://what3words.com/\(encoded)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Preview on what3words", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Pickup Location")
                } footer: {
                    Text("A location puts your item on the map and shows buyers how far away it is. Nearby listings sell faster.")
                        .font(.caption)
                }
                
                Section {
                    Button(action: createListing) {
                        if isCreating {
                            HStack {
                                ProgressView()
                                Text("Creating...")
                            }
                        } else {
                            Text("Create Listing")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || isCreating)
                }
            }
            .navigationTitle("List Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if sellerName.isEmpty {
                    sellerName = MarketplaceIdentity.sellerDisplayName
                }
            }
            .task { await connect.refreshAccountStatus() }
            .sheet(isPresented: $showPayoutSetup) {
                PayoutSetupSheet()
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    /// Whether this seller can actually receive online payments. Listing is
    /// allowed either way (Tap to Pay and cash at pickup still work), but the
    /// seller should know before buyers find out.
    @ViewBuilder
    private var payoutStatusRow: some View {
        if connect.chargesEnabled {
            Label {
                Text("Online payouts ready")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.subheadline)
        } else {
            Button {
                showPayoutSetup = true
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connect.accountId == nil ? "Set up payouts" : "Finish payout setup")
                                .font(.subheadline)
                            Text("Needed for Apple Pay and card payments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "banknote").foregroundStyle(.indigo)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }
    
    private func createListing() {
        guard isValid else { return }
        
        guard let priceValue = parsedPrice, priceValue > 0 else {
            errorMessage = "Enter a price greater than zero."
            showError = true
            return
        }

        // The listing's sellerID must be the same id orders and Stripe Connect
        // use, otherwise the seller can never manage it or get paid for it.
        guard let currentUserID = MarketplaceIdentity.currentUserID else {
            errorMessage = marketplaceManager.sellingBlockedReason
                ?? "Sign in to iCloud in Settings to list items for sale."
            showError = true
            return
        }
        
        isCreating = true
        
        let trimmedName = sellerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedW3W = what3Words.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = P2PListing(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            price: priceValue,
            currency: currency,
            sellerName: trimmedName,
            sellerID: currentUserID,
            imageData: imageData,
            location: capturedLocation,
            what3WordsLocation: trimmedW3W.isEmpty ? nil : trimmedW3W
        )

        Task {
            do {
                try await marketplaceManager.addListing(listing)
                MarketplaceIdentity.rememberSellerDisplayName(trimmedName)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                isCreating = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func captureLocationAndFetchW3W() {
        isCapturingLocation = true
        geoManager.startMonitoring()
        Task {
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let loc = await MainActor.run(body: { geoManager.userLocation }) {
                    await MainActor.run {
                        capturedLocation = loc
                        isCapturingLocation = false
                        isFetchingW3W = true
                    }
                    let words = await fetchWhat3Words(lat: loc.latitude, lng: loc.longitude)
                    await MainActor.run {
                        if let words { what3Words = words }
                        isFetchingW3W = false
                    }
                    return
                }
            }
            await MainActor.run { isCapturingLocation = false }
        }
    }
}

// MARK: - Helpers

/// Accepts "12.50", "12,50" and " 12 " — people type prices the way their
/// keyboard and locale suggest, not the way Decimal(string:) expects.
private func parseDecimal(_ text: String) -> Decimal? {
    let cleaned = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
        .filter { $0.isNumber || $0 == "." }
    guard !cleaned.isEmpty else { return nil }
    return Decimal(string: cleaned)
}

/// Converts GPS coordinates to a what3words address using the REST API.
/// Requires a valid API key at kW3WApiKey.
private func fetchWhat3Words(lat: Double, lng: Double) async -> String? {
    guard !kW3WApiKey.isEmpty, kW3WApiKey != "YOUR_W3W_API_KEY" else { return nil }
    let urlString = "https://api.what3words.com/v3/convert-to-3wa?coordinates=\(lat),\(lng)&key=\(kW3WApiKey)&language=en"
    guard let url = URL(string: urlString) else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    struct W3WResponse: Decodable { let words: String? }
    return (try? JSONDecoder().decode(W3WResponse.self, from: data))?.words
}

// MARK: - P2P Listing Detail View

struct P2PListingDetailView: View {
    let listing: P2PListing
    @ObservedObject var marketplaceManager: P2PMarketplaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var showStripeCheckout = false
    @State private var showManageListing = false
    @State private var showSellerProfile = false
    @State private var showTapToPayCollect = false
    @State private var showMarkSoldConfirm = false
    @State private var actionError: String?

    /// Live copy of the listing so edits made in the Manage sheet (or a sale)
    /// show here without closing and reopening.
    private var current: P2PListing {
        marketplaceManager.listings.first { $0.id == listing.id } ?? listing
    }

    private var isOwner: Bool { MarketplaceIdentity.owns(listing) }

    private var shouldShowBuyButtons: Bool {
        #if DEBUG
        // Show buy buttons even on your own listings so the payment flow
        // can be exercised in dev. Stripe will reject self-purchases server-side.
        return current.isAvailable
        #else
        return current.isAvailable && !isOwner
        #endif
    }

    /// Apple Pay needs only PassKit + the backend; card checkout also needs
    /// the PaymentSheet SDK. Either one is enough to open checkout.
    private var canPayOnline: Bool {
        StripeConfig.isConfigured && (StripeConfig.canUseInAppCardCheckout || PKPaymentAuthorizationController.canMakePayments())
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Product image
                    if let uiImage = UIImage.frydgeBounded(data: current.imageData, maxPixelSize: ImageBudget.display) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        ZStack {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 300)
                            
                            Image(systemName: "photo")
                                .font(.system(size: 80))
                                .foregroundStyle(.secondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // Title and price
                        Text(current.title)
                            .font(.title)
                            .fontWeight(.bold)
                        
                        HStack {
                            Text(current.formattedPrice)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.accent)
                            
                            Spacer()
                            
                            if current.isAvailable {
                                Label("Available", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.green)
                            } else {
                                Label("Sold", systemImage: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        }

                        Text("Listed \(current.createdAt, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        // Description
                        Text("Description")
                            .font(.headline)
                        Text(current.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        // Seller info — tap to view profile
                        Button {
                            showSellerProfile = true
                        } label: {
                            HStack {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.blue.opacity(0.14))
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.blue)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isOwner ? "Your listing" : "Seller")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(current.sellerName)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 4) {
                                    Text("View Profile")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        // what3words pickup location
                        if let w3w = current.what3WordsLocation, !w3w.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Pickup Location", systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    let encoded = w3w.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? w3w
                                    if let url = URL(string: "https://what3words.com/\(encoded)") {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("///\(w3w)")
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.blue)
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)

                                Text("what3words — tap to open in maps")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let coordinate = current.location {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Pickup Location", systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    openInMaps(coordinate, name: current.title)
                                } label: {
                                    Label("Open in Maps", systemImage: "map")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Seller-side: collect an in-person sale on this iPhone.
                    // Small vendors sell face to face — the buyer taps their
                    // card or phone on the seller's device via Tap to Pay.
                    if isOwner && current.isAvailable {
                        VStack(spacing: 10) {
                            Button {
                                showTapToPayCollect = true
                            } label: {
                                HStack {
                                    Image(systemName: "wave.3.right")
                                    Text("Collect Payment — Tap to Pay")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                            }

                            Button {
                                showMarkSoldConfirm = true
                            } label: {
                                Text("Mark as Sold")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if shouldShowBuyButtons {
                        VStack(spacing: 10) {
                            if canPayOnline {
                                Button {
                                    showStripeCheckout = true
                                } label: {
                                    HStack {
                                        Image(systemName: "bag.fill")
                                        Text("Buy for \(current.formattedPrice)")
                                    }
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                                }

                                Text("Apple Pay or card · Secured by Stripe")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                paymentUnavailableNotice
                            }

                            Label {
                                Text("Prefer to pay at pickup? The seller can take contactless cards and Apple Pay on their phone with Tap to Pay.")
                            } icon: {
                                Image(systemName: "wave.3.right")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Product Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isOwner {
                        Button {
                            showManageListing = true
                        } label: {
                            Label("Manage", systemImage: "pencil.circle")
                        }
                    } else {
                        ShareLink(item: "\(current.title) — \(current.formattedPrice)\nSeller: \(current.sellerName)\nFound on the Frydge marketplace") {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showManageListing) {
                EditP2PListingView(listing: current, marketplaceManager: marketplaceManager) {
                    dismiss()
                }
            }
            .sheet(isPresented: $showTapToPayCollect) {
                MarketplaceTapToPayView(listing: current) { success in
                    showTapToPayCollect = false
                    guard success else { return }
                    Task {
                        do {
                            try await marketplaceManager.markSold(current)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
            .sheet(isPresented: $showSellerProfile) {
                SellerProfileView(
                    sellerName: current.sellerName,
                    sellerID: current.sellerID,
                    marketplaceManager: marketplaceManager
                )
            }
            .sheet(isPresented: $showStripeCheckout) {
                MarketplaceCheckoutView(
                    listing: current,
                    onPaymentComplete: {
                        Task {
                            await marketplaceManager.recordPurchase(of: current)
                            await MainActor.run { dismiss() }
                        }
                    }
                )
            }
            .confirmationDialog("Mark this listing as sold?", isPresented: $showMarkSoldConfirm, titleVisibility: .visible) {
                Button("Mark as Sold") {
                    Task {
                        do {
                            try await marketplaceManager.markSold(current)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Buyers will see it as sold. You can make it available again from Manage.")
            }
            .alert("Couldn't update listing", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    /// Shown to buyers when online payment can't happen on this build. In
    /// release that's a plain "arrange it with the seller"; developers get the
    /// specific reason so they can fix the configuration.
    private var paymentUnavailableNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Online payment isn't available right now")
                    .font(.subheadline.weight(.semibold))
                #if DEBUG
                Text(StripeConfig.isConfigured
                     ? "Add StripePaymentSheet (or enable Apple Pay) to let buyers pay in-app."
                     : "Add the publishable key and backend URL in Payment Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Message the seller to arrange payment at pickup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func openInMaps(_ coordinate: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = name
        item.openInMaps()
    }
}

// MARK: - Edit / Manage Listing View

struct EditP2PListingView: View {
    let listing: P2PListing
    @ObservedObject var marketplaceManager: P2PMarketplaceManager
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var geoManager = GeoLocationManager()

    @State private var title: String
    @State private var description: String
    @State private var price: String
    @State private var currency: String
    @State private var isAvailable: Bool
    @State private var what3Words: String
    @State private var capturedLocation: CLLocationCoordinate2D?
    @State private var imageData: Data?
    @State private var selectedImage: PhotosPickerItem?
    @State private var isCapturingLocation = false
    @State private var isFetchingW3W = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage = ""
    @State private var showError = false

    init(listing: P2PListing, marketplaceManager: P2PMarketplaceManager, onDeleted: @escaping () -> Void) {
        self.listing = listing
        self.marketplaceManager = marketplaceManager
        self.onDeleted = onDeleted
        _title       = State(initialValue: listing.title)
        _description = State(initialValue: listing.description)
        _price       = State(initialValue: "\(listing.price)")
        _currency    = State(initialValue: listing.currency)
        _isAvailable = State(initialValue: listing.isAvailable)
        _what3Words  = State(initialValue: listing.what3WordsLocation ?? "")
        _capturedLocation = State(initialValue: listing.location)
        _imageData   = State(initialValue: listing.imageData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Listing Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    HStack {
                        TextField("Price", text: $price)
                            .keyboardType(.decimalPad)
                        Picker("Currency", selection: $currency) {
                            Text("NZD").tag("NZD")
                            Text("USD").tag("USD")
                            Text("GBP").tag("GBP")
                            Text("EUR").tag("EUR")
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("Available for sale", isOn: $isAvailable)
                }

                Section("Photo") {
                    PhotosPicker(selection: $selectedImage, matching: .images) {
                        if let uiImage = UIImage.frydgeBounded(data: imageData, maxPixelSize: ImageBudget.display) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Label("Add a Photo", systemImage: "photo")
                        }
                    }
                    .onChange(of: selectedImage) { _, newValue in
                        Task {
                            if let data = try? await newValue?.loadTransferable(type: Data.self) {
                                imageData = data
                            }
                        }
                    }
                    if imageData != nil {
                        Button("Remove Photo", role: .destructive) {
                            imageData = nil
                            selectedImage = nil
                        }
                    }
                }

                Section {
                    // Current GPS status
                    if let loc = capturedLocation {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Location captured")
                                    .font(.subheadline)
                                Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                capturedLocation = nil
                            }
                            .font(.caption)
                        }
                    }

                    // Use My Location button
                    Button {
                        captureCurrentLocation()
                    } label: {
                        if isCapturingLocation {
                            HStack { ProgressView().scaleEffect(0.85); Text("Getting location…") }
                        } else if isFetchingW3W {
                            HStack { ProgressView().scaleEffect(0.85); Text("Looking up what3words…") }
                        } else {
                            Label(
                                capturedLocation == nil ? "Use My Location" : "Update Location",
                                systemImage: "location.circle.fill"
                            )
                        }
                    }
                    .disabled(isCapturingLocation || isFetchingW3W)

                    // what3words field
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.blue)
                        TextField("e.g. filled.count.soap", text: $what3Words)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    if !what3Words.isEmpty {
                        Button {
                            let encoded = what3Words.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? what3Words
                            if let url = URL(string: "https://what3words.com/\(encoded)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Preview on what3words", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Pickup Location")
                } footer: {
                    Text("GPS location places a pin on the map. what3words gives buyers an ultra-precise address.")
                        .font(.caption)
                }

                Section {
                    Button(action: saveListing) {
                        if isSaving {
                            HStack { ProgressView(); Text("Saving…") }
                        } else {
                            Text("Save Changes")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSaving || isDeleting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Text("Delete Listing")
                        }
                    }
                    .disabled(isSaving || isDeleting)
                }
            }
            .navigationTitle("Manage Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Delete this listing?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteListing() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone. If it has sold, mark it unavailable instead so your sales history stays intact.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func captureCurrentLocation() {
        isCapturingLocation = true
        geoManager.startMonitoring()
        Task {
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let loc = await MainActor.run(body: { geoManager.userLocation }) {
                    await MainActor.run {
                        capturedLocation = loc
                        isCapturingLocation = false
                        isFetchingW3W = true
                    }
                    let words = await fetchWhat3Words(lat: loc.latitude, lng: loc.longitude)
                    await MainActor.run {
                        if let words, what3Words.isEmpty { what3Words = words }
                        isFetchingW3W = false
                    }
                    return
                }
            }
            await MainActor.run { isCapturingLocation = false }
        }
    }

    private func saveListing() {
        guard let priceValue = parseDecimal(price), priceValue > 0 else {
            errorMessage = "Enter a price greater than zero."
            showError = true
            return
        }
        isSaving = true
        let trimmedW3W = what3Words.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = listing
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.price = priceValue
        updated.currency = currency
        updated.isAvailable = isAvailable
        updated.imageData = imageData
        updated.location = capturedLocation
        updated.what3WordsLocation = trimmedW3W.isEmpty ? nil : trimmedW3W
        updated.updatedAt = Date()

        Task {
            do {
                try await marketplaceManager.updateListing(updated)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func deleteListing() {
        isDeleting = true
        Task {
            do {
                try await marketplaceManager.deleteListing(listing)
                await MainActor.run {
                    dismiss()
                    onDeleted()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - Seller Profile View

struct SellerProfileView: View {
    let sellerName: String
    let sellerID: String
    @ObservedObject var marketplaceManager: P2PMarketplaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedListing: P2PListing?

    private var sellerListings: [P2PListing] {
        marketplaceManager.listings
            .filter { $0.sellerID == sellerID }
            .sorted {
                if $0.isAvailable != $1.isAvailable { return $0.isAvailable }
                return $0.createdAt > $1.createdAt
            }
    }

    private var availableCount: Int { sellerListings.filter(\.isAvailable).count }
    private var soldCount: Int { sellerListings.count - availableCount }

    private var isMe: Bool {
        MarketplaceIdentity.currentUserID == sellerID || MarketplaceIdentity.legacyIDs.contains(sellerID)
    }

    private var summaryLine: String {
        var parts: [String] = []
        parts.append("\(availableCount) for sale")
        if soldCount > 0 { parts.append("\(soldCount) sold") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Seller header
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.14))
                                .frame(width: 72, height: 72)
                            Image(systemName: "person.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(sellerName)
                                .font(.title2.weight(.bold))
                            Text(summaryLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let first = sellerListings.map(\.createdAt).min() {
                                Text("Selling since \(first, format: .dateTime.month(.wide).year())")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // Location section (from most recent listing with location)
                    if let locationListing = sellerListings.first(where: { $0.what3WordsLocation != nil || $0.location != nil }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Pickup Location")
                                .font(.headline)
                                .padding(.horizontal)

                            if let w3w = locationListing.what3WordsLocation, !w3w.isEmpty {
                                Button {
                                    let encoded = w3w.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? w3w
                                    if let url = URL(string: "https://what3words.com/\(encoded)") {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("///\(w3w)")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.blue)
                                            Text("Tap to open in maps")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(.blue)
                                    }
                                    .padding(14)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    .padding(.horizontal)
                                }
                                .buttonStyle(.plain)
                            } else if let coordinate = locationListing.location {
                                Button {
                                    let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                                    item.name = sellerName
                                    item.openInMaps()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "map")
                                            .foregroundStyle(.blue)
                                        Text("Open pickup spot in Maps")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.blue)
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(.blue)
                                    }
                                    .padding(14)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    .padding(.horizontal)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()
                            .padding(.horizontal)
                    }

                    // Listings grid
                    VStack(alignment: .leading, spacing: 12) {
                        Text(isMe ? "Your Listings" : "What They're Selling")
                            .font(.headline)
                            .padding(.horizontal)

                        if sellerListings.isEmpty {
                            Text("No active listings right now.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(sellerListings) { listing in
                                    Button {
                                        selectedListing = listing
                                    } label: {
                                        HStack(spacing: 12) {
                                            if let img = UIImage.frydgeBounded(data: listing.imageData, maxPixelSize: ImageBudget.thumbnail) {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 64, height: 64)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                    .saturation(listing.isAvailable ? 1 : 0)
                                            } else {
                                                ZStack {
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color.gray.opacity(0.15))
                                                    Image(systemName: "photo")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .frame(width: 64, height: 64)
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(listing.title)
                                                    .font(.body.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)

                                                Text(listing.formattedPrice)
                                                    .font(.subheadline)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.accent)

                                                if listing.isAvailable {
                                                    Label("Available", systemImage: "checkmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.green)
                                                } else {
                                                    Label("Sold", systemImage: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.red)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(14)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                        .padding(.horizontal)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(isMe ? "My Profile" : "Seller Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedListing) { listing in
                P2PListingDetailView(listing: listing, marketplaceManager: marketplaceManager)
            }
            .task {
                if marketplaceManager.listings.isEmpty {
                    await marketplaceManager.fetchListings()
                }
            }
        }
    }
}
