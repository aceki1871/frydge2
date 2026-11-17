//
//  VendorMarketplaceView.swift
//  FrydgeRecipes
//
//  Created on 27/04/2026.
//

import SwiftUI
import PassKit

struct VendorMarketplaceView: View {
    @StateObject private var productManager = VendorProductManager()
    @StateObject private var paymentHandler = ApplePaymentHandler()
    @State private var showAddProduct = false
    @State private var selectedProduct: VendorProduct?
    @State private var showPaymentSuccess = false
    @State private var searchText = ""
    @State private var selectedCategory: VendorProduct.ProductCategory?
    @Environment(\.colorScheme) var colorScheme
    
    var filteredProducts: [VendorProduct] {
        var products = productManager.products
        
        // Filter by search text
        if !searchText.isEmpty {
            products = products.filter { product in
                product.name.localizedCaseInsensitiveContains(searchText) ||
                product.description.localizedCaseInsensitiveContains(searchText) ||
                product.vendorName.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Filter by category
        if let category = selectedCategory {
            products = products.filter { $0.category == category }
        }
        
        return products
    }
    
    var body: some View {
        ZStack {
            // Background matching theme
            (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        FilterChip(
                            title: "All",
                            isSelected: selectedCategory == nil
                        ) {
                            selectedCategory = nil
                        }
                        
                        ForEach(VendorProduct.ProductCategory.allCases, id: \.self) { category in
                            FilterChip(
                                title: category.rawValue,
                                isSelected: selectedCategory == category
                            ) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(
                    (colorScheme == .dark ? 
                     Color(uiColor: .systemGray6).opacity(0.3) : 
                     Color(uiColor: .systemGray6))
                )
                
                // Products list
                if productManager.isLoading {
                    Spacer()
                    ProgressView("Loading products...")
                    Spacer()
                } else if filteredProducts.isEmpty {
                    ContentUnavailableView {
                        Label("No Products Found", systemImage: "shippingbox")
                    } description: {
                        Text(searchText.isEmpty ? "Add your first product to get started" : "Try a different search")
                    } actions: {
                        if searchText.isEmpty {
                            Button("Add Product") {
                                showAddProduct = true
                            }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredProducts) { product in
                                ProductCard(product: product) {
                                    selectedProduct = product
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search products or vendors")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddProduct = true
                } label: {
                    Label("Add Product", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showAddProduct) {
            AddProductView(productManager: productManager)
        }
        .sheet(item: $selectedProduct) { product in
            ProductDetailView(
                product: product,
                paymentHandler: paymentHandler,
                onPaymentSuccess: {
                    showPaymentSuccess = true
                }
            )
        }
        .alert("Payment Successful!", isPresented: $showPaymentSuccess) {
            Button("OK") { }
        } message: {
            Text("Your purchase has been completed successfully.")
        }
        .task {
            await productManager.fetchAllProducts()
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? 
                           (colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.08)) : 
                           (colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.2)))
                .foregroundStyle(isSelected ? 
                               (colorScheme == .dark ? .white : .black) : 
                               .secondary)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Product Card

struct ProductCard: View {
    let product: VendorProduct
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Product image. Loaded asynchronously with cache + retry;
                // the previous `Data(contentsOf:)` here blocked the main
                // thread on a network call inside `body`.
                CachedAsyncImage(url: product.imageURL) { phase in
                    if case .success(let image) = phase {
                        // Locked to the card's width and a fixed height so a
                        // wide photo can't stretch the layout.
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .clipped()
                    } else {
                        ZStack {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 200)

                            Image(systemName: "photo")
                                .font(.system(size: 50))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                // Product info
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            Text(product.vendorName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(product.formattedPrice)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                            
                            if product.isAvailable {
                                Label("Available", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("Unavailable", systemImage: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    
                    HStack {
                        Label(product.category.rawValue, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(
                (colorScheme == .dark ? 
                 Color(uiColor: .systemGray6).opacity(0.5) : 
                 Color.white)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), 
                   radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Product Detail View

struct ProductDetailView: View {
    let product: VendorProduct
    @ObservedObject var paymentHandler: ApplePaymentHandler
    let onPaymentSuccess: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var showPaymentError = false
    
    var totalPrice: Decimal {
        product.price * Decimal(quantity)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Product image (async, cached, retried — never a blocking
                    // network read inside `body`).
                    CachedAsyncImage(url: product.imageURL) { phase in
                        if case .success(let image) = phase {
                            image
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
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // Title and vendor
                        Text(product.name)
                            .font(.title)
                            .fontWeight(.bold)
                        
                        HStack {
                            Label(product.vendorName, systemImage: "storefront")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            if product.isAvailable {
                                Label("Available", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.green)
                            } else {
                                Label("Unavailable", systemImage: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        }
                        
                        Divider()
                        
                        // Description
                        Text("Description")
                            .font(.headline)
                        Text(product.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        // Category
                        HStack {
                            Text("Category")
                                .font(.headline)
                            Spacer()
                            Text(product.category.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        
                        Divider()
                        
                        // Price and quantity
                        VStack(spacing: 16) {
                            HStack {
                                Text("Price per item")
                                    .font(.headline)
                                Spacer()
                                Text(product.formattedPrice)
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }
                            
                            HStack {
                                Text("Quantity")
                                    .font(.headline)
                                
                                Spacer()
                                
                                HStack(spacing: 16) {
                                    Button {
                                        if quantity > 1 {
                                            quantity -= 1
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title2)
                                    }
                                    .disabled(quantity <= 1)
                                    
                                    Text("\(quantity)")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .frame(minWidth: 40)
                                    
                                    Button {
                                        quantity += 1
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                    }
                                }
                            }
                            
                            HStack {
                                Text("Total")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Spacer()
                                Text(formatPrice(totalPrice))
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.accent)
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Apple Pay button
                    if paymentHandler.canMakePayments {
                        Button {
                            paymentHandler.startPayment(for: product, quantity: quantity) { success in
                                if success {
                                    onPaymentSuccess()
                                    dismiss()
                                } else {
                                    showPaymentError = true
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "apple.logo")
                                Text("Pay with Apple Pay")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.black, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!product.isAvailable)
                    } else {
                        Text("Apple Pay is not available on this device")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Product Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert("Payment Error", isPresented: $showPaymentError) {
                Button("OK") { }
            } message: {
                Text(paymentHandler.errorMessage ?? "An error occurred while processing your payment")
            }
        }
    }
    
    private func formatPrice(_ price: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = product.currency
        return formatter.string(from: price as NSDecimalNumber) ?? "\(price)"
    }
}

#Preview {
    VendorMarketplaceView()
}
