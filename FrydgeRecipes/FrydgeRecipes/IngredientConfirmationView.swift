import SwiftUI

struct IngredientConfirmationView: View {
    @Binding var ingredients: String  // Single ingredient

    var body: some View {
        VStack {
            Text("Confirm Ingredients")
                .font(.title)
                .padding()

            HStack {
                Text("Ingredients: ")
                    .fontWeight(.bold)
                Text(ingredients)  // Display single ingredient
            }
            .padding()

            Spacer()

            Button(action: {
                print("Ingredients confirmed: \(ingredients)")
            }) {
                Text("Confirm Ingredients")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top)
        }
        .navigationTitle("Confirm Ingredients")
        .padding()
    }
}
