import SwiftUI
import CloudKit
import UserNotifications
import ActivityKit

struct NotificationDiagnosticView: View {
    @State private var notificationStatus: String = "Checking..."
    @State private var cloudKitStatus: String = "Checking..."
    @State private var liveActivityStatus: String = "Checking..."
    @State private var apnsTokenStatus: String = "Checking..."
    @State private var activeActivityCount: String = "—"
    @State private var subscriptionInfo: [String] = []
    @State private var isLoading = false
    
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Notification Permission")
                    Spacer()
                    Text(notificationStatus)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("iCloud Status")
                    Spacer()
                    Text(cloudKitStatus)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Live Activities")
                    Spacer()
                    Text(liveActivityStatus)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Active Activities")
                    Spacer()
                    Text(activeActivityCount)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("APNs Token")
                    Spacer()
                    Text(apnsTokenStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("System Status")
            }
            
            Section {
                if subscriptionInfo.isEmpty {
                    Text("No subscriptions found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(subscriptionInfo, id: \.self) { info in
                        Text(info)
                            .font(.caption)
                    }
                }
            } header: {
                HStack {
                    Text("CloudKit Subscriptions")
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            
            Section {
                Button {
                    Task {
                        await runDiagnostics()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                        Spacer()
                    }
                }
                .disabled(isLoading)
                
                Button {
                    Task {
                        await requestNotificationPermission()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Request Notification Permission", systemImage: "bell.badge")
                        Spacer()
                    }
                }
                .disabled(isLoading)

                Button {
                    startTestLiveActivity()
                } label: {
                    HStack {
                        Spacer()
                        Label("Start Test Live Activity", systemImage: "cart.fill.badge.plus")
                        Spacer()
                    }
                }

                Button(role: .destructive) {
                    ActivityManager.endActivity()
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await refreshLiveActivityState()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("End All Live Activities", systemImage: "stop.circle")
                        Spacer()
                    }
                }
            } header: {
                Text("Actions")
            }
        }
        .navigationTitle("Notification Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await runDiagnostics()
        }
    }
    
    // MARK: - Diagnostics
    
    private func runDiagnostics() async {
        isLoading = true
        defer { isLoading = false }
        
        await checkNotificationStatus()
        await checkCloudKitStatus()
        await fetchSubscriptions()
        await refreshLiveActivityState()
        refreshAPNsTokenState()
    }

    private func refreshLiveActivityState() async {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        liveActivityStatus = enabled ? "✅ Enabled" : "❌ Disabled (Settings → Frydge → Live Activities)"
        let count = Activity<ShoppingListActivityAttributes>.activities.count
        activeActivityCount = "\(count)"
    }

    private func refreshAPNsTokenState() {
        if let token = UserDefaults.standard.string(forKey: "APNsDeviceToken"), !token.isEmpty {
            let prefix = token.prefix(10)
            let suffix = token.suffix(6)
            apnsTokenStatus = "✅ \(prefix)…\(suffix) (len=\(token.count))"
        } else {
            apnsTokenStatus = "❌ Not registered"
        }
    }

    private func startTestLiveActivity() {
        print("[DIAG] Starting test Live Activity. areActivitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        ActivityManager.startActivity(for: "Test Store")
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshLiveActivityState()
        }
    }
    
    private func checkNotificationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        switch settings.authorizationStatus {
        case .authorized:
            notificationStatus = "✅ Authorized"
        case .denied:
            notificationStatus = "❌ Denied"
        case .notDetermined:
            notificationStatus = "⚠️ Not Determined"
        case .provisional:
            notificationStatus = "⚠️ Provisional"
        case .ephemeral:
            notificationStatus = "⚠️ Ephemeral"
        @unknown default:
            notificationStatus = "❓ Unknown"
        }
    }
    
    private func checkCloudKitStatus() async {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                cloudKitStatus = "✅ Available"
            case .noAccount:
                cloudKitStatus = "❌ No Account"
            case .restricted:
                cloudKitStatus = "❌ Restricted"
            case .couldNotDetermine:
                cloudKitStatus = "❓ Could Not Determine"
            case .temporarilyUnavailable:
                cloudKitStatus = "⚠️ Temporarily Unavailable"
            @unknown default:
                cloudKitStatus = "❓ Unknown"
            }
        } catch {
            cloudKitStatus = "❌ Error: \(error.localizedDescription)"
        }
    }
    
    private func fetchSubscriptions() async {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        subscriptionInfo = []
        
        // Check private database subscriptions
        do {
            let privateDB = container.privateCloudDatabase
            let privateSubs = try await privateDB.allSubscriptions()
            
            for sub in privateSubs {
                subscriptionInfo.append("📱 Private: \(sub.subscriptionID)")
            }
        } catch {
            subscriptionInfo.append("❌ Private DB error: \(error.localizedDescription)")
        }
        
        // Check shared database subscriptions
        do {
            let sharedDB = container.sharedCloudDatabase
            let sharedSubs = try await sharedDB.allSubscriptions()
            
            for sub in sharedSubs {
                subscriptionInfo.append("👥 Shared: \(sub.subscriptionID)")
            }
        } catch {
            subscriptionInfo.append("❌ Shared DB error: \(error.localizedDescription)")
        }
        
        if subscriptionInfo.isEmpty {
            subscriptionInfo.append("No active subscriptions found")
        }
    }
    
    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                notificationStatus = "✅ Authorized"
            } else {
                notificationStatus = "❌ Denied"
            }
        } catch {
            notificationStatus = "❌ Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - CKDatabase Extension

private extension CKDatabase {
    func allSubscriptions() async throws -> [CKSubscription] {
        try await withCheckedThrowingContinuation { continuation in
            self.fetchAllSubscriptions { subscriptions, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: subscriptions ?? [])
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        NotificationDiagnosticView()
    }
}
