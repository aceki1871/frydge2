import SwiftUI

struct GotYourPanView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pans: [String] = [] // Replace PansManager with manual state
    @State private var newPan: String = ""
    @FocusState private var isInputActive: Bool
    @Environment(\.colorScheme) var colorScheme

    var recipePans: [String] // List of pans required for the recipe

    var body: some View {
        VStack {
            Text("Syncing...")
                .font(.footnote)
                .foregroundColor(.green)
                .padding(.top, 5)

            Spacer().frame(height: 20)

            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title)
                        .foregroundColor(.blue)
                }

                Spacer()

                Text("Frydge")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()
            }
            .padding(.top, 5)

            Text("Your Pans")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 10)
                .padding(.bottom, 10)

            HStack {
                TextField("Enter new pan", text: $newPan)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isInputActive)
                    .padding(.horizontal)
                Button(action: {
                    addPan()
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.blue)
                }
            }
            .padding(.bottom, 10)

            Text("This Might Be Useful")
                .font(.headline)
                .padding(.top, 10)

            List {
                ForEach(pans, id: \.self) { pan in
                    HStack {
                        Text(pan)
                        Spacer()
                    }
                }
            }
            .frame(height: 150)

            Text("Might Need This")
                .font(.headline)
                .padding(.top, 10)

            List {
                ForEach(recipePans.filter { !pans.contains($0) }, id: \.self) { requiredPan in
                    HStack {
                        Text(requiredPan)
                        Spacer()
                    }
                }
            }
            .frame(height: 150)

            Spacer()
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        .onAppear {
            loadPans() // Load the pans manually here
        }
        .navigationBarHidden(true)
    }

    private func loadPans() {
        // Fetch or load pans manually from a data source (CloudRecipe or other)
        pans = ["Frying Pan", "Saucepan"] // Example data
    }

    private func addPan() {
        guard !newPan.isEmpty else { return }
        pans.append(newPan)
        newPan = ""
    }
}
