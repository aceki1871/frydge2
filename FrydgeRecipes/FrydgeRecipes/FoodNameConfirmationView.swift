import SwiftUI

struct FoodNameConfirmationView: View {
    @Binding var foodName: String

    var body: some View {
        VStack {
            Text("Confirm or Edit the Food Name")
                .font(.title)
            TextField("Food Name", text: $foodName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
        }
    }
}
