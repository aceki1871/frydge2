import Foundation
import WatchConnectivity

/// Receives shopping-list summaries pushed from the iOS app via WatchConnectivity.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var storeName: String?
    @Published var distanceText: String?
    @Published var itemCount: Int = 0
    @Published var totalCostText: String?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        applyContext(WCSession.default.applicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        storeName = context["storeName"] as? String
        distanceText = context["distanceText"] as? String
        itemCount = context["itemCount"] as? Int ?? 0
        totalCostText = context["totalCostText"] as? String
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            applyContext(session.applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            applyContext(applicationContext)
        }
    }
}
