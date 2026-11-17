//
//  StripeConnectManager.swift
//  FrydgeRecipes
//
//  Manages Stripe Connect Express onboarding for marketplace sellers.
//
//  Usage in your ProfileView / seller settings:
//    StripeConnectView()       — shows onboarding button + status
//

import SwiftUI
import AuthenticationServices

// MARK: - Persistence keys

private enum ConnectKeys {
    static let accountId = "frydge.stripe.connectAccountId"
}

// MARK: - Manager

@MainActor
final class StripeConnectManager: NSObject, ObservableObject {
    static let shared = StripeConnectManager()

    /// Was a hardcoded copy of the URL. Reads the single source of truth so a
    /// user-configured backend actually takes effect here too.
    private var backendBaseURL: String { StripeConfig.backendBaseURL }

    // The seller's Stripe Connect account ID (acct_...) — persisted to UserDefaults
    @Published private(set) var accountId: String? {
        didSet { UserDefaults.standard.set(accountId, forKey: ConnectKeys.accountId) }
    }

    @Published private(set) var chargesEnabled = false
    @Published private(set) var payoutsEnabled = false
    @Published private(set) var detailsSubmitted = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private override init() {
        accountId = UserDefaults.standard.string(forKey: ConnectKeys.accountId)
        super.init()
    }

    /// The CloudKit user record name — the same value marketplace order calls
    /// send as `sellerUserId`. The backend uses it to map this user to their
    /// Connect account so order payments can resolve the account server-side.
    private var sellerUserId: String? {
        let id = UserDefaults.standard.string(forKey: "appleUserID")
        return (id?.isEmpty == false) ? id : nil
    }

    // MARK: - Onboarding

    /// Starts the Stripe Connect Express onboarding flow.
    /// Opens a web sheet; on completion the user's accountId is stored.
    func startOnboarding(email: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let returnURL  = "frydge://stripe-connect-return"
        let refreshURL = "frydge://stripe-connect-refresh"

        guard let url = URL(string: "\(backendBaseURL)/connect/onboard") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&req)
        var body: [String: Any] = [
            "email": email,
            "returnUrl": returnURL,
            "refreshUrl": refreshURL,
        ]
        body["sellerUserId"] = sellerUserId
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                errorMessage = json?["error"] as? String ?? "Onboarding failed."
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let acctId = json?["accountId"] as? String,
                  let onboardingURLString = json?["onboardingUrl"] as? String,
                  let onboardingURL = URL(string: onboardingURLString) else {
                errorMessage = "Invalid onboarding response."
                return
            }

            // Store immediately so we can poll status after web flow completes
            accountId = acctId

            // Open Stripe's onboarding page in an ASWebAuthenticationSession
            // (this handles the redirect back to the app via the frydge:// URL scheme)
            try await openOnboardingWebFlow(url: onboardingURL, callbackScheme: "frydge")

            // Refresh status once the user returns
            await refreshAccountStatus()

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-opens onboarding for an existing accountId (e.g. if user didn't finish).
    func resumeOnboarding() async {
        guard let acctId = accountId else {
            errorMessage = "No account found. Please start onboarding first."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "\(backendBaseURL)/connect/onboard") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&req)
        var body: [String: Any] = [
            "email": "",           // Not used for existing accounts — backend ignores it
            "existingAccountId": acctId,
            "returnUrl": "frydge://stripe-connect-return",
            "refreshUrl": "frydge://stripe-connect-refresh",
        ]
        body["sellerUserId"] = sellerUserId
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                errorMessage = json?["error"] as? String ?? "Couldn't reach Stripe to resume setup. Please try again."
                return
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let urlStr = json?["onboardingUrl"] as? String,
                  let onboardingURL = URL(string: urlStr) else {
                errorMessage = "Stripe didn't return a setup link. Please try again."
                return
            }
            try await openOnboardingWebFlow(url: onboardingURL, callbackScheme: "frydge")
            await refreshAccountStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Status

    func refreshAccountStatus() async {
        guard let acctId = accountId else { return }
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "\(backendBaseURL)/connect/account-status") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FrydgeBackend.authorize(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId": acctId])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            chargesEnabled   = json?["chargesEnabled"]   as? Bool ?? false
            payoutsEnabled   = json?["payoutsEnabled"]   as? Bool ?? false
            detailsSubmitted = json?["detailsSubmitted"] as? Bool ?? false
        } catch {}
    }

    /// Clears the saved Connect account (e.g. if user wants to re-link).
    func clearAccount() {
        accountId = nil
        chargesEnabled = false
        payoutsEnabled = false
        detailsSubmitted = false
        UserDefaults.standard.removeObject(forKey: ConnectKeys.accountId)
    }

    // MARK: - Web auth session

    private func openOnboardingWebFlow(url: URL, callbackScheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { _, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume()   // User cancelled — not a hard error
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension StripeConnectManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
                return window
            }
            if let scene = scenes.first {
                return ASPresentationAnchor(windowScene: scene)
            }
            // Unreachable: an auth session can't be presenting without a connected scene.
            preconditionFailure("No connected UIWindowScene available to anchor the web auth session")
        }
    }
}

// MARK: - StripeConnectView

/// Drop this into ProfileView / seller settings to show onboarding + status.
struct StripeConnectView: View {
    @StateObject private var manager = StripeConnectManager.shared
    @AppStorage("frydge.profileEmail") private var profileEmail = ""
    @State private var showEmailEntry = false
    @State private var sellerEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.indigo)
                Text("Receive Payments")
                    .font(.headline)
            }

            if manager.accountId == nil {
                // Not yet onboarded
                Text("Set up secure payouts to receive money from buyers. Stripe handles your bank details and identity checks — Frydge never sees or stores them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // If we already know the user's email, one tap goes straight to
                // Stripe's hosted onboarding. Otherwise ask for it inline first.
                if showEmailEntry {
                    VStack(spacing: 10) {
                        TextField("Your email", text: $sellerEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                        Button {
                            let email = sellerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !email.isEmpty else { return }
                            Task { await manager.startOnboarding(email: email) }
                        } label: {
                            if manager.isLoading {
                                HStack(spacing: 8) { ProgressView(); Text("Setting up…") }
                            } else {
                                Text("Continue to Stripe →")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(sellerEmail.isEmpty || manager.isLoading)
                    }
                } else {
                    Button {
                        let email = sellerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                        if email.isEmpty {
                            showEmailEntry = true
                        } else {
                            Task { await manager.startOnboarding(email: email) }
                        }
                    } label: {
                        if manager.isLoading {
                            HStack(spacing: 8) { ProgressView(); Text("Setting up…") }
                        } else {
                            Text("Set up payouts")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(manager.isLoading)
                }

            } else {
                // Account exists — show status
                accountStatusView

                if !manager.chargesEnabled {
                    Button("Complete setup →") {
                        Task { await manager.resumeOnboarding() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }

            if let err = manager.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task { await manager.refreshAccountStatus() }
        .onAppear {
            if sellerEmail.isEmpty {
                sellerEmail = profileEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var accountStatusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Details submitted", ok: manager.detailsSubmitted)
            statusRow("Can accept payments", ok: manager.chargesEnabled)
            statusRow("Payouts enabled",     ok: manager.payoutsEnabled)
        }
    }

    private func statusRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
                .font(.subheadline)
        }
    }
}
