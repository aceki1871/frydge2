import SwiftUI

// Ingredient model (updated to handle a single string)
struct Ingredient: Identifiable {
    let id: UUID = UUID()
    var name: String
    var quantity: Double
    var unit: String
}

// Main view for adding ingredients
struct AddIngredientView: View {
    @State private var searchText: String = ""
    @State private var ingredients: String = ""  // Now a single ingredient string
    @State private var availableIngredients: [String] = [] // Simulated database of ingredients
    @State private var showAddPopup: Bool = false
    @State private var selectedIngredient: String = ""
    @State private var quantity: Double = 1.0
    @State private var unit: String = "g" // Default unit

    var body: some View {
        VStack {
            // Search bar with magnifying glass
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search for ingredients...", text: $searchText)
                    .onChange(of: searchText) {
                        filterAvailableIngredients(for: searchText)
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()

            // List of available ingredients
            List {
                ForEach(availableIngredients.filter { $0.lowercased().contains(searchText.lowercased()) }, id: \.self) { ingredient in
                    Button(action: {
                        selectedIngredient = ingredient
                        showAddPopup = true
                    }) {
                        Text(ingredient)
                    }
                }

                if !availableIngredients.contains(where: { $0.lowercased() == searchText.lowercased() }) && !searchText.isEmpty {
                    Button(action: {
                        selectedIngredient = searchText
                        showAddPopup = true
                    }) {
                        Text("Add '\(searchText)'")
                            .foregroundColor(.blue)
                    }
                }
            }

            // Popup for adding ingredient details
            if showAddPopup {
                VStack {
                    Text("Add Ingredient Details")
                        .font(.headline)
                    HStack {
                        Text("Ingredient:")
                        Text(selectedIngredient)
                    }
                    HStack {
                        Text("Quantity:")
                        TextField("Quantity", value: $quantity, formatter: NumberFormatter())
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Unit:")
                        Picker("Unit", selection: $unit) {
                            Text("g").tag("g")
                            Text("kg").tag("kg")
                            Text("lb").tag("lb")
                            Text("ea").tag("ea")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    Button("Done") {
                        addIngredient()
                        showAddPopup = false
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
                .padding()
            }
        }
        .navigationTitle("Add Ingredients")
    }

    // Function to filter available ingredients
    private func filterAvailableIngredients(for searchText: String) {
        // Simulated available ingredients
        availableIngredients = ["Chicken", "Beef", "Pork", "Tomato", "Lettuce", "Cheese"]
    }

    // Function to add the selected ingredient to the recipe
    private func addIngredient() {
        ingredients = selectedIngredient  // Single ingredient, not an array
        print("Added Ingredients: \(ingredients)")
    }
}
