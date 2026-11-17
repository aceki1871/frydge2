//
//  LocalMarketplaceView.swift
//  FrydgeRecipes
//
//  Created on 27/04/2026.
//

import SwiftUI
import CoreLocation
import MapKit

/// Unified view combining Marketplace, Map, and List functionality
struct LocalMarketplaceView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Open straight onto the current user's own listings (Profile › Marketplace › My Listings).
    var startWithMyListings = false

    @Environment(\.colorScheme) var colorScheme
    // Default to .market — Map is loaded lazily to avoid Metal MSAA crash on first appearance.
    @State private var selectedTab: MarketplaceTab = .market
    // The Map is only inserted into the hierarchy after the user taps the Map tab.
    // Once mounted it stays alive (opacity toggle) to avoid the Metal teardown crash.
    @State private var mapHasBeenShown = false
    @State private var mapIsReady = false
    @StateObject private var marketplaceManager = P2PMarketplaceManager()

    enum MarketplaceTab: String, CaseIterable, Identifiable {
        case market = "Market"
        case map = "Map"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .map: return "map.fill"
            case .market: return "storefront"
            }
        }
    }

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerWithTabs

                // GeometryReader captures a valid non-zero frame BEFORE the map is
                // inserted — passing explicit dimensions prevents MKMapView/Metal from
                // receiving a 0×0 drawable size, which causes the MSAA resolve crash.
                GeometryReader { geo in
                    let validFrame = geo.size.width > 0 && geo.size.height > 0
                    ZStack {
                        // Map mounts only once we have a valid frame AND the user has
                        // tapped the Map tab. Once mounted it stays alive (opacity toggle).
                        if mapHasBeenShown && validFrame {
                            LocalMapView(marketplaceManager: marketplaceManager)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(selectedTab == .map ? 1 : 0)
                                .allowsHitTesting(selectedTab == .map && mapIsReady)
                        }

                        P2PMarketplaceView(
                            marketplaceManager: marketplaceManager,
                            startWithMyListings: startWithMyListings
                        )
                        .opacity(selectedTab == .market ? 1 : 0)
                        .allowsHitTesting(selectedTab == .market)

                        // Smooth loading overlay shown while map initialises
                        if selectedTab == .map && !mapIsReady {
                            ZStack {
                                (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
                                VStack(spacing: 14) {
                                    ProgressView()
                                        .scaleEffect(1.3)
                                        .tint(.blue)
                                    Text("Loading Map…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(horizontalSizeClass == .regular ? .visible : .hidden, for: .navigationBar)
        .onChange(of: selectedTab) { _, tab in
            if tab == .map {
                mapHasBeenShown = true
                mapIsReady = false
                Task {
                    // Wait for Metal to complete its first render pass before revealing map
                    try? await Task.sleep(for: .milliseconds(1000))
                    withAnimation(.easeIn(duration: 0.25)) { mapIsReady = true }
                }
            }
        }
    }
    
    // ✅ Sleek header with pill-style tab selector
    private var headerWithTabs: some View {
        VStack(spacing: 12) {
            // Title
            Text("Marketplace")
                .font(.system(size: 28, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            
            // ✅ Pill-style tab selector (longer, slimmer)
            HStack(spacing: 0) {
                ForEach(MarketplaceTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab ?
                            AnyView(
                                Capsule()
                                    .fill(Color.blue)
                                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                            ) :
                            AnyView(Capsule().fill(Color.clear))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ?
                         Color(uiColor: .systemGray6).opacity(0.3) :
                         Color(uiColor: .systemGray6))
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(
            (colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground))
                .ignoresSafeArea(edges: .top)
        )
    }
}

// MARK: - Local Map View

struct LocalMapView: View {
    @ObservedObject var marketplaceManager: P2PMarketplaceManager

    var body: some View {
        // GoLocalView already applies .ignoresSafeArea() on its content —
        // a second .ignoresSafeArea() here fights the explicit .frame() set
        // by the GeometryReader in LocalMarketplaceView and can cause Metal
        // to receive a 0×0 drawable, crashing the MSAA resolve pass.
        GoLocalView(marketplaceManager: marketplaceManager)
    }
}

// MARK: - Local Store List View

struct LocalStoreListView: View {
    @StateObject private var locationManager = LocationManager()
    @State private var selectedStore: Store?
    @Environment(\.colorScheme) var colorScheme
    
    private var sortedStores: [Store] {
        guard let userLocation = locationManager.location else {
            return locationManager.stores.sorted { $0.name < $1.name }
        }
        
        return locationManager.stores.sorted {
            let lhsDistance = distance(from: userLocation, to: $0)
            let rhsDistance = distance(from: userLocation, to: $1)
            return lhsDistance < rhsDistance
        }
    }
    
    private func distance(from userLocation: CLLocation, to store: Store) -> Double {
        let storeLocation = CLLocation(latitude: store.latitude, longitude: store.longitude)
        return userLocation.distance(from: storeLocation)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
                    .ignoresSafeArea()
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sortedStores) { store in
                            StoreListCard(store: store, userLocation: locationManager.location)
                                .onTapGesture {
                                    selectedStore = store
                                }
                        }
                    }
                    .padding()
                }
            }
            .navigationDestination(item: $selectedStore) { store in
                StoreLocalBrowseView(store: store)
            }
            .onAppear {
                locationManager.startUpdatingLocation()
            }
        }
    }
}

// MARK: - Store List Card

struct StoreListCard: View {
    let store: Store
    let userLocation: CLLocation?
    @Environment(\.colorScheme) var colorScheme
    
    private var distanceText: String {
        guard let userLocation = userLocation else {
            return ""
        }
        
        let storeLocation = CLLocation(latitude: store.latitude, longitude: store.longitude)
        let distanceInMeters = userLocation.distance(from: storeLocation)
        let distanceInMiles = distanceInMeters / 1609.34
        
        if distanceInMiles < 0.1 {
            return "Nearby"
        } else if distanceInMiles < 1 {
            return String(format: "%.1f mi", distanceInMiles)
        } else {
            return String(format: "%.0f mi", distanceInMiles)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Store Logo
            storeLogo(for: store.name)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            // Store Info
            VStack(alignment: .leading, spacing: 6) {
                Text(store.name)
                    .font(.headline)
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                    .lineLimit(2)
                
                if !store.vicinity.isEmpty {
                    Text(store.vicinity)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                if !distanceText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                        Text(distanceText)
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? 
                     Color(uiColor: .systemGray6).opacity(0.5) : 
                     Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), 
                       radius: 8, x: 0, y: 2)
        )
    }
    
    // Function to load correct logo for store
    @ViewBuilder
    private func storeLogo(for storeName: String) -> some View {
        let name = storeName.lowercased().replacingOccurrences(of: " ", with: "")
        
        if name.contains("pak") || name.contains("paknsave") {
            Image("paknsave")
                .resizable()
                .scaledToFit()
        } else if name.contains("countdown") || name.contains("woolworths") {
            Image("countdown")
                .resizable()
                .scaledToFit()
        } else if name.contains("clark") {
            Image("clarkcakes")
                .resizable()
                .scaledToFit()
        } else if name.contains("tanks") {
            Image("dad")
                .resizable()
                .scaledToFit()
        } else if name.contains("unichem") {
            Image("unichem")
                .resizable()
                .scaledToFit()
        } else if name.contains("tesco") {
            Image("tesco")
                .resizable()
                .scaledToFit()
        } else if name.contains("sainsbury") {
            Image("sainsburys")
                .resizable()
                .scaledToFit()
        } else if name.contains("newworld") {
            Image("newworld")
                .resizable()
                .scaledToFit()
        } else if name.contains("chemist") {
            Image("chemistwarehouse")
                .resizable()
                .scaledToFit()
        } else if name.contains("morrison") {
            Image("morrisons")
                .resizable()
                .scaledToFit()
        } else if name.contains("pharmacy") || name.contains("lloyds") {
            Image("lloydspharmacy")
                .resizable()
                .scaledToFit()
        } else if name.contains("foursquare") {
            Image("foursquare")
                .resizable()
                .scaledToFit()
        } else if name.contains("waitrose") {
            Image("waitrose")
                .resizable()
                .scaledToFit()
        } else if name.contains("aldi") {
            Image("aldi")
                .resizable()
                .scaledToFit()
        } else if name.contains("marks") || name.contains("m&s") {
            Image("mands")
                .resizable()
                .scaledToFit()
        } else if name.contains("co-op") || name.contains("coop") {
            Image("coop")
                .resizable()
                .scaledToFit()
        } else if name.contains("boots") {
            Image("boots")
                .resizable()
                .scaledToFit()
        } else if name.contains("asda") {
            Image("asda")
                .resizable()
                .scaledToFit()
        } else {
            // No "lidl" asset exists in the catalog; unknown brands (Lidl
            // included) fall through to the generic storefront symbol rather
            // than rendering an empty frame.
            Image(systemName: "building.2.crop.circle")
                .resizable()
                .foregroundColor(.gray)
                .padding(8)
        }
    }
}

// MARK: - P2P Marketplace View

struct P2PMarketplaceView: View {
    @ObservedObject var marketplaceManager: P2PMarketplaceManager
    var startWithMyListings = false

    @ObservedObject private var connect = StripeConnectManager.shared
    @StateObject private var geo = GeoLocationManager()

    @State private var showAddListing = false
    // One-time optional Sign in with Apple offer before the first listing.
    @State private var showSignInPrompt = false
    @State private var showOrders = false
    @State private var showPayoutSetup = false
    @State private var sellingBlockedMessage: String?
    @State private var selectedListing: P2PListing?
    @State private var selectedSeller: (name: String, id: String)?
    @State private var searchText = ""
    @State private var showOnlyMine = false
    @State private var showSold = false
    @State private var sortOrder: SortOrder = .newest
    @State private var hasAppliedInitialFilter = false
    @Environment(\.colorScheme) var colorScheme

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case nearest = "Nearest first"
        var id: String { rawValue }
    }

    private var userLocation: CLLocation? {
        geo.userLocation.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Sellers with live listings but no way to get paid online yet.
    private var needsPayoutSetup: Bool {
        !marketplaceManager.myListings.isEmpty && !connect.chargesEnabled
    }

    var filteredListings: [P2PListing] {
        var base = marketplaceManager.listings
        if showOnlyMine {
            // Owners want to see everything they've posted, sold or not.
            base = base.filter(MarketplaceIdentity.owns)
        } else if !showSold {
            base = base.filter { $0.isAvailable }
        }
        if !searchText.isEmpty {
            base = base.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.sellerName.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOrder {
        case .newest:
            // Available items first, newest within each group.
            return base.sorted {
                if $0.isAvailable != $1.isAvailable { return $0.isAvailable }
                return $0.createdAt > $1.createdAt
            }
        case .nearest:
            let here = userLocation
            return base.sorted {
                let lhs = $0.distance(from: here) ?? .greatestFiniteMagnitude
                let rhs = $1.distance(from: here) ?? .greatestFiniteMagnitude
                if lhs != rhs { return lhs < rhs }
                return $0.createdAt > $1.createdAt
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
                    .ignoresSafeArea()
                
                if marketplaceManager.isLoading && marketplaceManager.listings.isEmpty {
                    ProgressView("Loading marketplace…")
                } else if let errorMessage = marketplaceManager.errorMessage, marketplaceManager.listings.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") {
                            Task { await load() }
                        }
                    }
                } else if filteredListings.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if let errorMessage = marketplaceManager.errorMessage {
                                inlineNotice(errorMessage, systemImage: "wifi.exclamationmark", tint: .orange)
                            }
                            if needsPayoutSetup {
                                payoutNudge
                            }
                            ForEach(filteredListings) { listing in
                                P2PListingCard(
                                    listing: listing,
                                    distanceText: listing.distanceText(from: userLocation),
                                    isMine: MarketplaceIdentity.owns(listing),
                                    onAuthorTap: {
                                        selectedSeller = (listing.sellerName, listing.sellerID)
                                    }
                                ) {
                                    selectedListing = listing
                                }
                            }
                        }
                        .padding()
                    }
                    .refreshable { await load() }
                }
            }
            .searchable(text: $searchText, prompt: "Search products or sellers")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Toggle(isOn: $showOnlyMine.animation()) {
                            Label("My listings", systemImage: "person")
                        }
                        Toggle(isOn: $showSold.animation()) {
                            Label("Show sold items", systemImage: "tag.slash")
                        }
                        .disabled(showOnlyMine)
                        Picker("Sort", selection: $sortOrder.animation()) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: showOnlyMine || showSold || sortOrder != .newest
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startListing()
                    } label: {
                        Label("List an item", systemImage: "plus.circle")
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showOrders = true
                    } label: {
                        Label("Orders", systemImage: "shippingbox")
                    }
                }
            }
            .sheet(isPresented: $showAddListing) {
                AddP2PListingView(marketplaceManager: marketplaceManager)
            }
            .sheet(isPresented: $showSignInPrompt) {
                AppleSignInPromptSheet(actionDescription: "list an item for sale") {
                    showAddListing = true
                }
            }
            .sheet(isPresented: $showOrders) {
                MarketplaceOrdersView()
            }
            .sheet(isPresented: $showPayoutSetup) {
                PayoutSetupSheet()
            }
            .sheet(item: $selectedListing) { listing in
                P2PListingDetailView(listing: listing, marketplaceManager: marketplaceManager)
            }
            .sheet(item: Binding(
                get: { selectedSeller.map { SellerSheetIdentifier(name: $0.name, id: $0.id) } },
                set: { if $0 == nil { selectedSeller = nil } }
            )) { seller in
                SellerProfileView(
                    sellerName: seller.name,
                    sellerID: seller.id,
                    marketplaceManager: marketplaceManager
                )
            }
            .alert("Can't list right now", isPresented: Binding(
                get: { sellingBlockedMessage != nil },
                set: { if !$0 { sellingBlockedMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(sellingBlockedMessage ?? "")
            }
            .task { await load() }
            .onAppear {
                geo.startMonitoring()
                if startWithMyListings && !hasAppliedInitialFilter {
                    showOnlyMine = true
                    hasAppliedInitialFilter = true
                }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if showOnlyMine {
            ContentUnavailableView {
                Label("Nothing listed yet", systemImage: "storefront")
            } description: {
                Text("Items you put up for sale will appear here, where you can edit them or mark them sold.")
            } actions: {
                Button("List an Item") { startListing() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing for sale yet", systemImage: "basket")
            } description: {
                Text("Be the first to sell spare produce, baking or pantry extras to people nearby.")
            } actions: {
                Button("List an Item") { startListing() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var payoutNudge: some View {
        Button {
            showPayoutSetup = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "banknote.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connect.accountId == nil ? "Get paid online" : "Finish payout setup")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(connect.accountId == nil
                         ? "Buyers can pay with Apple Pay or card once you link a payout account. Takes a couple of minutes with Stripe."
                         : "Stripe still needs a few details before buyers can pay you online.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func inlineNotice(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    /// Fetch listings, then — for sellers — pull sales so anything already
    /// paid for is flipped to sold, and check whether payouts are set up.
    private func load() async {
        await marketplaceManager.fetchListings()
        guard !marketplaceManager.myListings.isEmpty,
              MarketplaceIdentity.currentUserID != nil else { return }
        await connect.refreshAccountStatus()
        await MarketplaceOrderService.shared.refreshOrders(role: .seller)
        await marketplaceManager.reconcileSoldListings(with: MarketplaceOrderService.shared.sellerOrders)
    }

    /// Selling needs an iCloud account (the listing is a CloudKit record the
    /// seller must own). First listing: offer (don't require) an Apple ID link
    /// so buyers see the seller's name. Otherwise go straight to the form.
    private func startListing() {
        if let reason = marketplaceManager.sellingBlockedReason {
            sellingBlockedMessage = reason
            Task { await marketplaceManager.refreshAccountStatus() }
        } else if AppleSignInGate.shouldOfferBeforeSharing {
            showSignInPrompt = true
        } else {
            showAddListing = true
        }
    }
}

private struct SellerSheetIdentifier: Identifiable {
    let name: String
    let id: String
}

// MARK: - Payout setup sheet

/// Stripe Connect onboarding, reachable from inside the marketplace so a
/// seller doesn't have to hunt through Profile to start getting paid.
struct PayoutSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StripeConnectView()

                    Text("Payments are processed securely by Stripe. Bank details and identity checks are handled on Stripe's hosted pages — Frydge never sees or stores them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Get Paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - P2P Listing Card (Liquid Glass Design)

struct P2PListingCard: View {
    let listing: P2PListing
    var distanceText: String? = nil
    var isMine = false
    var onAuthorTap: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    /// What the buyer most wants to know under the price: how far away it is,
    /// or failing that whether the seller has shared a pickup spot at all.
    private var pickupLabel: (icon: String, text: String) {
        if let distanceText { return ("location.fill", distanceText) }
        if listing.hasPickupLocation { return ("mappin.and.ellipse", "Pickup location shared") }
        return ("bubble.left", "Arrange pickup with seller")
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Product image with glass overlay
                ZStack(alignment: .topTrailing) {
                    if let imageData = listing.imageData,
                       let uiImage = UIImage.frydgeBounded(data: imageData, maxPixelSize: ImageBudget.display) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .clipped()
                            .saturation(listing.isAvailable ? 1 : 0)
                            .opacity(listing.isAvailable ? 1 : 0.6)
                    } else {
                        ZStack {
                            // Soft gradient background instead of flat gray
                            LinearGradient(
                                colors: [
                                    Color(white: 0.3, opacity: 0.15),
                                    Color(white: 0.2, opacity: 0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(height: 200)
                            
                            Image(systemName: "photo")
                                .font(.system(size: 50))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    
                    // Status badges with glass effect
                    HStack(spacing: 8) {
                        if isMine {
                            Text("Yours")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.blue.opacity(0.85), in: Capsule())
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(listing.isAvailable ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(listing.isAvailable ? "Available" : "Sold")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(12)
                }
                
                // Listing info with glass effect
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(listing.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            Button {
                                onAuthorTap?()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 12))
                                    Text(listing.sellerName)
                                        .font(.system(size: 13))
                                    if onAuthorTap != nil {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9))
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .disabled(onAuthorTap == nil)
                        }
                        
                        Spacer()
                        
                        Text(listing.formattedPrice)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    
                    if !listing.description.isEmpty {
                        Text(listing.description)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    
                    Divider()
                        .background(.white.opacity(0.15))
                    
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: pickupLabel.icon)
                                .font(.system(size: 12))
                            Text(pickupLabel.text)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        
                        Spacer()
                        
                        Text(listing.createdAt, format: .relative(presentation: .named))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(16)
                .background(
                    // Liquid Glass dark silver/grey background
                    ZStack {
                        // Base glass layer with dark silver gradient
                        LinearGradient(
                            colors: [
                                Color(white: 0.25, opacity: 0.8),
                                Color(white: 0.18, opacity: 0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        
                        // Subtle light reflection
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.clear,
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        
                        // Ultra thin material for glass blur effect
                        Rectangle()
                            .fill(.ultraThinMaterial.opacity(0.3))
                    }
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                // Subtle glass border
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listing.title), \(listing.formattedPrice), \(listing.isAvailable ? "available" : "sold"), sold by \(listing.sellerName)")
    }
}

#Preview {
    LocalMarketplaceView()
}
