import SwiftUI

struct ManualProduct: ProductProtocol {
    var productName: String?
    var ingredientsList: String?
    var quantityValue: Int?
}

struct ManualProductInputView: View {
    @State private var productName: String = ""
    @State private var ingredients: String = ""
    @State private var quantity: Int?
    @ObservedObject var productViewModel: ProductViewModel  // Inject ProductViewModel
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Product Name", text: $productName)
                TextField("Quantity", value: $quantity, format: .number)
                    .keyboardType(.numberPad)
                TextField("Ingredients (comma separated)", text: $ingredients)
                Button("Save") {
                    if let quantityInt = quantity {
                        productViewModel.handleManualEntry(
                            productName: productName,
                            ingredients: ingredients,
                            quantity: String(quantityInt)
                        )
                    } else {
                        print("Invalid quantity")
                    }
                }
                .disabled(productName.isEmpty || quantity == nil)
            }
            .navigationTitle("Manual Product Entry")
        }
    }
}
