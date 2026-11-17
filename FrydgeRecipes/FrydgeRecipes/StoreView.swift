import SwiftUI
import MapKit

struct StoreView: View {
    var store: Store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            storeLogo
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(store.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 14) {
                    if let mapsURL = mapsDirectionsURL() {
                        Link(destination: mapsURL) {
                            Image(systemName: "car.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    if let phoneURL = phoneURL() {
                        Link(destination: phoneURL) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    if let websiteURL = websiteURL() {
                        Link(destination: websiteURL) {
                            Image(systemName: "globe")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }

    @ViewBuilder
    private var storeLogo: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 64, height: 64)
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .offset(x: -6, y: 6)

            logoImage
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var logoImage: some View {
        let storeName = normalizedStoreName(store.name)

        if storeName.contains("pak") {
            Image("paknsave")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("countdown") || storeName.contains("woolworth") {
            Image("countdown")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("new world") {
            Image("newworld")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("chemist warehouse") {
            Image("chemistwarehouse")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("unichem") {
            Image("unichem")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("tesco") {
            Image("tesco")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("sainsbury") {
            Image("sainsburys")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("morrison") {
            Image("morrisons")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("four square") {
            Image("foursquare")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("co-op") || storeName.contains("coop") {
            Image("coop")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("boots") {
            Image("boots")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("aldi") {
            Image("aldi")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("waitrose") {
            Image("waitrose")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("marks") || storeName.contains("mands") {
            Image("mands")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if storeName.contains("asda") {
            Image("asda")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Image(systemName: "bag.fill")
                .resizable()
                .scaledToFit()
                .padding(16)
                .foregroundStyle(.blue)
        }
    }

    private func normalizedStoreName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var locationLabel: String {
        let full = store.vicinity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }

        let separators = [" - ", " – ", " — "]
        for separator in separators {
            if let firstPart = full.components(separatedBy: separator).first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !firstPart.isEmpty {
                return firstPart
            }
        }

        let parts = full.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count >= 2 {
            return parts[0]
        }

        return full
    }

    private func mapsDirectionsURL() -> URL? {
        let encodedAddress = store.vicinity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let query = encodedAddress.isEmpty ? store.name : encodedAddress
        return URL(string: "http://maps.apple.com/?daddr=\(query)")
    }

    private func phoneURL() -> URL? {
        guard let phoneNumber = store.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !phoneNumber.isEmpty else {
            return nil
        }

        let digits = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private func websiteURL() -> URL? {
        let website = store.website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !website.isEmpty else {
            return nil
        }
        return URL(string: website)
    }
}
