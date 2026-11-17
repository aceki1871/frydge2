import Foundation
import WatchConnectivity

/// Pushes a shopping summary to the paired Apple Watch via WatchConnectivity.
/// Called automatically each time the shopping list is saved.
final class WatchDataSender: NSObject {
    static let shared = WatchDataSender()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Reads the latest WidgetSnapshot and sends a compact summary to the Watch.
    func sendCurrentData(from snapshot: WidgetSnapshot) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }

        // Same quantity / currency / ticked-item logic as the widget, instead of
        // re-parsing display strings (which ignored quantity, counted items
        // already ticked off, and assumed every price was in dollars).
        let itemCount = snapshot.remainingItems.count

        var context: [String: Any] = ["itemCount": itemCount]
        if let total = snapshot.estimatedTotal, total.value > 0 {
            context["totalCostText"] = total.value.formatted(.currency(code: total.currencyCode))
            context["pricedItemCount"] = total.pricedCount
        }
        if let storeName = snapshot.nearestStoreName, !storeName.isEmpty {
            context["storeName"] = storeName
        }
        if let distanceText = snapshot.nearestStoreDistanceText, !distanceText.isEmpty {
            context["distanceText"] = distanceText
        }

        try? WCSession.default.updateApplicationContext(context)
    }
}

extension WatchDataSender: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
