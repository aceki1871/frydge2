import SwiftUI
import MapKit

struct StoreDetailView: View {
    var store: Store
    @ObservedObject var locationManager: LocationManager
    @Binding var isPresented: Bool  // Binding to control visibility

    var body: some View {
        VStack(spacing: 10) {
            // Close button at the top left
            HStack {
                Button(action: {
                    isPresented = false  // Dismiss the view
                }) {
                    Image(systemName: "xmark")
                        .resizable()
                        .frame(width: 10,height: 10)
                        .foregroundColor(.black)
                        .padding()
                        .background(Color.white.opacity(0.8))
                        .clipShape(Circle())
                        .shadow(radius: 3)
                }
                Spacer()
            }
            .padding(.top, 1)
            .padding(.leading)

            // Logo and store location name
            HStack {
                storeLogo(for: store.name)
                    .scaledToFit()
                    .frame(width: 75, height: 75)

                VStack(alignment: .leading, spacing: 5) {
                    Text(extractLocationName(from: store.name))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.black)
                    
                    // Store hours with dynamic color based on current time
                    let isOpen = checkIfStoreIsOpen(hours: store.storehours)
                    Text("Hours: \(store.storehours)")
                        .font(.subheadline)
                        .foregroundColor(isOpen ? .green : .red)
                }
                Spacer()
            }
            .padding()

            // Contact options: phone, website, and maps
            HStack(spacing: 30) {
                Button(action: callStore) {
                    Image(systemName: "phone.fill")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.blue)
                }
                
                Button(action: openWebsite) {
                    Image(systemName: "globe")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.blue)
                }
                
                Button(action: openInMaps) {
                    Image(systemName: "map")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.blue)
                }
            }
            .padding(.bottom, 1)

        }
        .padding()
        .background(Color.white)
        .cornerRadius(2)
        .shadow(radius: 1)
        .padding(.horizontal)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // Function to check if the store is open based on the provided hours string
    private func checkIfStoreIsOpen(hours: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"  // Assumes store hours are in 12-hour AM/PM format

        let timeComponents = hours.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        
        guard timeComponents.count == 2,
              let openingTime = formatter.date(from: timeComponents[0]),
              let closingTime = formatter.date(from: timeComponents[1]) else {
            return false
        }

        let calendar = Calendar.current
        let currentTime = Date()

        let openingDate = calendar.date(bySettingHour: calendar.component(.hour, from: openingTime),
                                        minute: calendar.component(.minute, from: openingTime),
                                        second: 0, of: currentTime)
        
        let closingDate = calendar.date(bySettingHour: calendar.component(.hour, from: closingTime),
                                        minute: calendar.component(.minute, from: closingTime),
                                        second: 0, of: currentTime)
        
        guard let openDate = openingDate, let closeDate = closingDate else {
            return false
        }

        return currentTime >= openDate && currentTime <= closeDate
    }

    // Function to load correct logo for store
    @ViewBuilder
    private func storeLogo(for storeName: String) -> some View {
        let name = storeName.lowercased().replacingOccurrences(of: " ", with: "")
        
        if name.contains("pak") {
            Image("paknsave").resizable()
        } else if name.contains("countdown") {
            Image("countdown").resizable()
        } else if name.contains("clark") {
            Image("clarkcakes").resizable()
        } else if name.contains("tanks") {
            Image("dad").resizable()
        } else if name.contains("unichem") {
            Image("unichem").resizable()
        } else if name.contains("tesco") {
            Image("tesco").resizable()
        } else if name.contains("sainsburys") {
            Image("sainsburys").resizable()
        } else if name.contains("newworld") {
            Image("newworld").resizable()
        } else if name.contains("chemistwarehouse") {
            Image("chemistwarehouse").resizable()
        } else if name.contains("morrison") {
            Image("morrisons").resizable()
        } else if name.contains("pharmacy") {
            Image("lloydspharmacy").resizable()
        } else if name.contains("foursquare") {
            Image("foursquare").resizable()
        } else if name.contains("waitrose") {
            Image("waitrose").resizable()
        } else if name.contains("aldi") {
            Image("aldi").resizable()
        } else if name.contains("mands") {
            Image("mands").resizable()
        } else if name.contains("co-op") {
            Image("coop").resizable()
        } else if name.contains("boots") {
            Image("boots").resizable()
        } else if name.contains("asda") {
            Image("asda").resizable()
        } else {
            Image(systemName: "building.2.crop.circle")
                .resizable()
                .foregroundColor(.gray)
        }
    }

    // Extracts location name based on certain keywords
    private func extractLocationName(from fullName: String) -> String {
        let keywords = ["north", "Oak", "Park", "downs", "Extra", "City", "Albert", "Lukes", "CBD", "Street"]
        let components = fullName.split(separator: " ")

        for (index, word) in components.enumerated() {
            if keywords.contains(String(word)) && index > 0 {
                return "\(components[index - 1]) \(word)"
            }
        }

        return components.last.map { String($0) } ?? fullName  // Default to last component if no match
    }

    // Opens the store location in Apple Maps
    private func openInMaps() {
        let storeLocation = CLLocation(latitude: store.latitude, longitude: store.longitude)
        // Deployment target is iOS 27, so the location-based initialiser is
        // always available and the deprecated MKPlacemark path is gone.
        let mapItem = MKMapItem(location: storeLocation, address: nil)
        mapItem.name = store.name
        mapItem.openInMaps(launchOptions: nil)
    }
    
    // Function to call the store's phone number
    private func callStore() {
        print("Attempting to call store")
        if let phoneNumber = store.phoneNumber, let phoneURL = URL(string: "tel:\(phoneNumber)") {
            UIApplication.shared.open(phoneURL)
        }
    }

    private func openWebsite() {
        print("Attempting to open website")
        if let websiteURL = URL(string: store.website) {
            UIApplication.shared.open(websiteURL)
        }
    }
}
