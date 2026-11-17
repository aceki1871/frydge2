//
//  AddProductView.swift
//  FrydgeRecipes
//
//  Created on 27/04/2026.
//

import SwiftUI
import PhotosUI

struct AddProductView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var productManager: VendorProductManager
    
    @State private var productName = ""
    @State private var productDescription = ""
    @State private var priceString = ""
    @State private var selectedCategory: VendorProduct.ProductCategory = .other
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var productImage: UIImage?
    @State private var isAvailable = true
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    
    // Vendor info - in a real app, this would come from user authentication
    @State private var vendorID = UUID().uuidString
    @State private var vendorName = "Local Vendor"
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Product Photo") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        if let productImage {
                            Image(uiImage: productImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Label("Select Product Photo", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity, minHeight: 200)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                
                Section("Product Details") {
                    TextField("Product Name", text: $productName)
                    
                    TextField("Description", text: $productDescription, axis: .vertical)
                        .lineLimit(3...6)
                    
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(VendorProduct.ProductCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }
                
                Section("Pricing") {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $priceString)
                            .keyboardType(.decimalPad)
                    }
                }
                
                Section("Availability") {
                    Toggle("Available for Purchase", isOn: $isAvailable)
                }
                
                Section("Vendor Information") {
                    TextField("Vendor Name", text: $vendorName)
                }
            }
            .navigationTitle("Add Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveProduct()
                        }
                    }
                    .disabled(isSaving || !isFormValid)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.1)
                            .ignoresSafeArea()
                        ProgressView("Saving Product...")
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .onChange(of: selectedPhoto) { oldValue, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload) {
                    productImage = image
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !productName.isEmpty &&
        !productDescription.isEmpty &&
        !priceString.isEmpty &&
        Decimal(string: priceString) != nil &&
        !vendorName.isEmpty
    }
    
    private func saveProduct() async {
        guard let price = Decimal(string: priceString) else {
            errorMessage = "Please enter a valid price"
            showError = true
            return
        }
        
        isSaving = true
        
        let product = VendorProduct(
            name: productName,
            description: productDescription,
            price: price,
            currency: "USD",
            vendorID: vendorID,
            vendorName: vendorName,
            category: selectedCategory,
            isAvailable: isAvailable
        )
        
        do {
            try await productManager.saveProduct(product, image: productImage)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            isSaving = false
        }
    }
}

#Preview {
    AddProductView(productManager: VendorProductManager())
}
