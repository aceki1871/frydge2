import SwiftUI

struct SaveRecipeView: View {
    @Binding var foodName: String
    @Binding var ingredients: [String]  // List of ingredients

    var body: some View {
        VStack {
            Text("Confirm and Save")
                .font(.title)
                .padding()

            HStack {
                Text("Recipe Name: ")
                    .fontWeight(.bold)
                Text(foodName)
            }
            .padding()

            HStack {
                Text("Ingredients: ")
                    .fontWeight(.bold)
                Text(ingredients.joined(separator: ", "))  // Join list into a single string
            }
            .padding()

            Spacer()

            Button(action: {
                // Save the recipe logic will go here
                print("Saving recipe: \(foodName) with ingredients \(ingredients.joined(separator: ", "))")
            }) {
                Text("Save Recipe")
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top)
        }
        .navigationTitle("Save Recipe")
        .padding()
    }
}
