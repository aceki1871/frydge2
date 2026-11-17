import CarPlay
import MapKit
import Foundation

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        showShoppingList(interfaceController: interfaceController)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    private func showShoppingList(interfaceController: CPInterfaceController) {
        let snapshot = WidgetSnapshot.read()
        let items = snapshot.items
        let itemCount = items.count
        let storeName = snapshot.nearestStoreName ?? ""
        let distanceText = snapshot.nearestStoreDistanceText

        // Sum item prices for total cost
        let total = items.compactMap { item -> Double? in
            guard let text = item.priceText else { return nil }
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""))
        }.reduce(0, +)
        let totalText = total > 0 ? String(format: "$%.2f", total) : "No prices"

        var listItems: [CPListItem] = []

        // Summary row — tap to navigate
        let summarySubtitle: String = {
            var parts: [String] = ["\(itemCount) item\(itemCount == 1 ? "" : "s")", "Total: \(totalText)"]
            if let d = distanceText { parts.insert(d, at: 0) }
            return parts.joined(separator: " · ")
        }()

        let summaryItem = CPListItem(text: storeName.isEmpty ? "Shopping List" : storeName,
                                    detailText: summarySubtitle)
        summaryItem.handler = { [weak self] _, completion in
            self?.openMapsNavigation(to: storeName)
            completion()
        }
        listItems.append(summaryItem)

        // Individual list items
        for item in items {
            let price = item.priceText.map { " · \($0)" } ?? ""
            let detail = (item.displayQuantity.map { "\($0)\(price)" } ?? price).trimmingCharacters(in: .init(charactersIn: " ·"))
            let row = CPListItem(text: item.name, detailText: detail.isEmpty ? nil : detail)
            listItems.append(row)
        }

        // If list is empty, show a placeholder
        if listItems.count == 1 {
            listItems.append(CPListItem(text: "Shopping list is empty", detailText: nil))
        }

        let section = CPListSection(items: listItems,
                                    header: "Shopping List",
                                    sectionIndexTitle: nil)
        let template = CPListTemplate(title: "Frydge", sections: [section])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    // MARK: - Navigation

    private func openMapsNavigation(to storeName: String) {
        guard !storeName.isEmpty else { return }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = storeName
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            guard let mapItem = response?.mapItems.first else { return }
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
        }
    }
}
