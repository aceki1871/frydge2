//
//  ClerkView.swift
//  FrydgeRecipes
//
//  Order management + Tap to Pay on iPhone via Stripe Terminal
//

import SwiftUI
import AuthenticationServices
#if canImport(StripeTerminal)
import StripeTerminal
#endif
import UserNotifications
import AudioToolbox

// MARK: - Terminal Token Route

/// Which backend mints Stripe Terminal connection tokens.
///
/// The clerk/store system (bigger businesses) uses per-store tokens behind a
/// clerk JWT. The P2P marketplace (small vendors) uses platform-account tokens
/// from the relay-key worker so sellers never need store credentials. A reader
/// session is bound to the account that minted its token, so switching routes
/// forces a reader reconnect.
enum TerminalTokenRoute {
    case clerkStore
    case marketplace
}

// MARK: - Stripe Terminal Connection Token Provider

#if canImport(StripeTerminal)
class FrydgeConnectionTokenProvider: NSObject, ConnectionTokenProvider {
    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        Task {
            do {
                let token: String
                switch await TerminalManager.shared.tokenRoute {
                case .marketplace:
                    token = try await MarketplaceOrderService.shared.fetchTerminalConnectionToken().secret
                case .clerkStore:
                    token = try await FrydgeAPIService.shared.fetchConnectionToken()
                }
                completion(token, nil)
            } catch {
                print("[TERMINAL] Failed to fetch connection token: \(error.localizedDescription)")
                completion(nil, error)
            }
        }
    }
}
#endif

// MARK: - Terminal Manager

#if canImport(StripeTerminal)
@MainActor
class TerminalManager: NSObject, ObservableObject {
    static let shared = TerminalManager()
    private let tokenProvider = FrydgeConnectionTokenProvider()

    /// Consulted by `FrydgeConnectionTokenProvider` every time the SDK asks for
    /// a token, including silent refreshes mid-session — so it must stay set to
    /// the active route for as long as the reader stays connected.
    private(set) var tokenRoute: TerminalTokenRoute = .clerkStore

    override init() {
        super.init()
        if !Terminal.isInitialized() {
            Terminal.initWithTokenProvider(tokenProvider, delegate: self)
        }
    }

    /// Switches the token route, disconnecting the reader first if it was
    /// connected under the other route's Stripe account.
    private func ensureRoute(_ route: TerminalTokenRoute) async throws {
        if tokenRoute != route, Terminal.shared.connectionStatus != .notConnected {
            print("[TERMINAL] switching token route \(tokenRoute) → \(route); disconnecting reader")
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Terminal.shared.disconnectReader { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        tokenRoute = route
    }

    func collectPayment(
        amount: Double,
        currency: String = "nzd",
        orderId: String,
        orgId: String? = nil,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        let resolvedOrgId = try await FrydgeAPIService.shared.resolveTerminalPaymentOrgId(
            orderId: orderId,
            explicitOrgId: orgId
        )
        FrydgeAPIService.shared.beginTerminalPayment(orgId: resolvedOrgId)
        defer { FrydgeAPIService.shared.endTerminalPayment() }

        // Standard flow: create the intent server-side, then collect.
        let intentResponse = try await FrydgeAPIService.shared.createTerminalPaymentIntent(
            amount: amount, orderId: orderId
        )
        try await collectPayment(
            amount: amount,
            currency: currency,
            orderId: orderId,
            orgId: resolvedOrgId,
            clientSecret: intentResponse.clientSecret,
            onState: onState
        )
    }

    /// Variant used when we already have a clientSecret (e.g. `frydge://collect` deep link).
    func collectPayment(
        amount: Double,
        currency: String = "nzd",
        orderId: String,
        orgId: String? = nil,
        clientSecret: String,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        let resolvedOrgId = try await FrydgeAPIService.shared.resolveTerminalPaymentOrgId(
            orderId: orderId,
            explicitOrgId: orgId
        )
        FrydgeAPIService.shared.beginTerminalPayment(orgId: resolvedOrgId)
        defer { FrydgeAPIService.shared.endTerminalPayment() }

        print("[TERMINAL] collect begin orderId=\(orderId) orgId=\(resolvedOrgId) amount=\(amount)")
        try await ensureRoute(.clerkStore)

        try await performCollection(
            clientSecret: clientSecret,
            locationId: StripeConfig.terminalLocationId,
            context: "orderId=\(orderId)",
            onState: onState
        )

        // Mark order paid (best-effort — the server already knows the intent state).
        do {
            try await FrydgeAPIService.shared.updateOrderStatus(orderId: orderId, status: "paid")
        } catch {
            print("[PAY] updateOrderStatus failed (paid): \(error)")
        }
        print("[TERMINAL] collect complete orderId=\(orderId)")
        onState(.success)
    }

    /// Marketplace variant: collects an in-person payment against a
    /// `MarketplaceOrder`'s PaymentIntent using the platform account, so small
    /// sellers never need clerk credentials or an org. The marketplace worker's
    /// Stripe webhook marks the order paid — there is no client-side status
    /// write here.
    func collectMarketplacePayment(
        clientSecret: String,
        locationId: String? = nil,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        try await ensureRoute(.marketplace)

        // Resolve the Terminal location: explicit → worker-provided → local setting.
        var resolvedLocation = locationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if resolvedLocation.isEmpty {
            resolvedLocation = (try? await MarketplaceOrderService.shared.fetchTerminalConnectionToken().locationId) ?? ""
        }
        if resolvedLocation.isEmpty {
            resolvedLocation = StripeConfig.terminalLocationId
        }

        print("[TERMINAL] marketplace collect begin locationId=\(resolvedLocation)")
        try await performCollection(
            clientSecret: clientSecret,
            locationId: resolvedLocation,
            context: "marketplace",
            onState: onState
        )
        print("[TERMINAL] marketplace collect complete")
        onState(.success)
    }

    /// Shared Tap to Pay sequence: connect reader → retrieve intent → collect
    /// card → confirm. Throws unless the intent ends `succeeded`; the caller
    /// reports `.success` after any follow-up bookkeeping.
    private func performCollection(
        clientSecret: String,
        locationId rawLocationId: String,
        context: String,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        onState(.connecting)

        // Connect to Tap to Pay reader if needed
        print("[TERMINAL] current connectionStatus=\(Terminal.shared.connectionStatus) paymentStatus=\(Terminal.shared.paymentStatus)")
        if Terminal.shared.connectionStatus != .connected {
            let locationId = rawLocationId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !locationId.isEmpty else {
                throw NSError(
                    domain: "Frydge",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Stripe Terminal Location ID is missing. Add a real tml_ location from the same Stripe account that mints this connection token."]
                )
            }

            let discoveryConfig = try TapToPayDiscoveryConfigurationBuilder().build()
            let connectionConfig = try TapToPayConnectionConfigurationBuilder(delegate: self, locationId: locationId)
                .build()
            let easyConfig = TapToPayEasyConnectConfiguration(
                discoveryConfiguration: discoveryConfig,
                connectionConfiguration: connectionConfig
            )
            print("[TERMINAL] connecting Tap to Pay reader locationId=\(locationId)")
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                _ = Terminal.shared.easyConnect(easyConfig) { _, error in
                    if let error = error {
                        print("[TERMINAL] reader connect FAILED: \(error.localizedDescription)")
                        if error.localizedDescription.localizedCaseInsensitiveContains("No such location") {
                            cont.resume(throwing: NSError(
                                domain: "Frydge",
                                code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "Stripe could not find Terminal location \(locationId). Create or select a Terminal location in the same Stripe account connected to this store, then save its tml_ ID in Payment Settings."]
                            ))
                        } else {
                            cont.resume(throwing: error)
                        }
                    } else {
                        print("[TERMINAL] reader connect OK")
                        cont.resume()
                    }
                }
            }
        } else {
            print("[TERMINAL] reader already connected")
        }

        print("[TERMINAL] connected connectionStatus=\(Terminal.shared.connectionStatus) paymentStatus=\(Terminal.shared.paymentStatus)")

        onState(.waiting)

        // Retrieve from Stripe Terminal
        print("[TERMINAL] retrievePaymentIntent start \(context)")
        let paymentIntent: PaymentIntent = try await withCheckedThrowingContinuation { cont in
            Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { intent, error in
                if let error = error {
                    print("[TERMINAL] retrievePaymentIntent FAILED: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
                else if let intent = intent {
                    print("[TERMINAL] retrievePaymentIntent OK status=\(intent.status)")
                    cont.resume(returning: intent)
                }
                else {
                    cont.resume(throwing: NSError(
                        domain: "Frydge",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Stripe did not return a payment intent."]
                    ))
                }
            }
        }

        // Collect - customer taps here
        print("[TERMINAL] collectPaymentMethod start \(context)")
        let collected: PaymentIntent = try await withCheckedThrowingContinuation { cont in
            Terminal.shared.collectPaymentMethod(paymentIntent) { collected, error in
                if let error = error {
                    print("[TERMINAL] collectPaymentMethod FAILED: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
                else if let collected = collected {
                    print("[TERMINAL] collectPaymentMethod OK status=\(collected.status)")
                    cont.resume(returning: collected)
                }
                else {
                    cont.resume(throwing: NSError(
                        domain: "Frydge",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Stripe did not return a collected payment intent."]
                    ))
                }
            }
        }

        onState(.processing)

        // Confirm payment
        print("[TERMINAL] confirmPaymentIntent start \(context)")
        let confirmed: PaymentIntent = try await withCheckedThrowingContinuation { cont in
            Terminal.shared.confirmPaymentIntent(collected) { confirmed, error in
                if let error = error {
                    print("[TERMINAL] confirmPaymentIntent FAILED: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
                else if let confirmed = confirmed {
                    print("[TERMINAL] confirmPaymentIntent OK status=\(confirmed.status)")
                    cont.resume(returning: confirmed)
                }
                else {
                    cont.resume(throwing: NSError(
                        domain: "Frydge",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Stripe did not return a confirmed payment intent."]
                    ))
                }
            }
        }

        guard confirmed.status == .succeeded else {
            print("[TERMINAL] payment not completed status=\(confirmed.status)")
            throw NSError(domain: "Frydge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Payment not completed"])
        }
    }
}

extension TerminalManager: TerminalDelegate {
    nonisolated func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {}
    nonisolated func terminal(_ terminal: Terminal, didChangeConnectionStatus status: ConnectionStatus) {}
    nonisolated func terminal(_ terminal: Terminal, didChangePaymentStatus status: PaymentStatus) {}
}

extension TerminalManager: TapToPayReaderDelegate {
    nonisolated func tapToPayReader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {}
    nonisolated func tapToPayReader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}
    nonisolated func tapToPayReader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}
    nonisolated func tapToPayReader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {}
    nonisolated func tapToPayReader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}
    nonisolated func tapToPayReaderDidAcceptTermsOfService(_ reader: Reader) {}
}
#else
// Fallback when StripeTerminal is not available
@MainActor
class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    func collectPayment(
        amount: Double,
        currency: String = "nzd",
        orderId: String,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        throw NSError(domain: "Frydge", code: -1, userInfo: [NSLocalizedDescriptionKey: "StripeTerminal SDK not available. Please add it to your project."])
    }

    func collectPayment(
        amount: Double,
        currency: String = "nzd",
        orderId: String,
        clientSecret: String,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        throw NSError(domain: "Frydge", code: -1, userInfo: [NSLocalizedDescriptionKey: "StripeTerminal SDK not available. Please add it to your project."])
    }

    func collectMarketplacePayment(
        clientSecret: String,
        locationId: String? = nil,
        onState: @escaping (TapToPayView.TapState) -> Void
    ) async throws {
        throw NSError(domain: "Frydge", code: -1, userInfo: [NSLocalizedDescriptionKey: "StripeTerminal SDK not available. Please add it to your project."])
    }
}
#endif

// MARK: - Clerk Root View

struct ClerkView: View {
    @StateObject private var api = FrydgeAPIService.shared
    
    var body: some View {
        Group {
            if !api.isLoggedIn { ClerkLoginView() }
            else if api.currentOrg == nil { ClerkOrgPickerView() }
            else { ClerkOrderBoardView() }
        }
        .task {
            if api.isLoggedIn && api.currentOrg == nil { await api.loadSavedOrg() }
        }
    }
}

// MARK: - Login

struct ClerkLoginView: View {
    @StateObject private var api = FrydgeAPIService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Text("🍳").font(.system(size: 60))
                Text("Frydge").font(.system(size: 32, weight: .black, design: .rounded))
                Text("Store Management").font(.subheadline).foregroundColor(.secondary)
            }.padding(.bottom, 40)
            
            VStack(spacing: 14) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                    .autocapitalization(.none).autocorrectionDisabled()
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                if let e = error { Text(e).font(.caption).foregroundColor(.red) }
                Button { Task { await signIn() } } label: {
                    Group {
                        if isLoading { ProgressView().tint(.white) }
                        else { Text("Sign In").font(.headline).foregroundColor(.white) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Color.blue).cornerRadius(12)
                }
                .disabled(isLoading || email.isEmpty || password.isEmpty)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task { await signInWithApple(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .disabled(isLoading)
            }.padding(.horizontal, 32)
            Spacer()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private func signIn() async {
        isLoading = true; error = nil
        do { try await api.login(email: email, password: password) }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func signInWithApple(_ result: Result<ASAuthorization, Error>) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                self.error = "Apple did not return a valid identity token."
                return
            }

            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let formatter = PersonNameComponentsFormatter()
            let fullName = credential.fullName.map { formatter.string(from: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)

            try await api.loginWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                fullName: fullName?.isEmpty == false ? fullName : nil
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Org Picker

struct ClerkOrgPickerView: View {
    @StateObject private var api = FrydgeAPIService.shared
    @State private var orgs: [FrydgeOrg] = []
    @State private var isLoading = true
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading { ProgressView("Loading stores...") }
                else if let e = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                        Text(e).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                    }.padding()
                } else {
                    List(orgs) { org in
                        Button { api.selectOrg(org) } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.blue).frame(width: 44, height: 44)
                                    Text(String(org.name.prefix(1)).uppercased())
                                        .font(.system(size: 20, weight: .black, design: .rounded)).foregroundColor(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(org.name).font(.headline).foregroundColor(.primary)
                                    Text(org.slug).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Select Store")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sign Out") { api.logout() }.foregroundColor(.red) } }
        }
        .task { await load() }
    }
    
    private func load() async {
        isLoading = true; error = nil
        do { orgs = try await api.fetchOrgs() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Order Board

struct ClerkOrderBoardView: View {
    @StateObject private var api = FrydgeAPIService.shared
    @State private var orders: [FrydgeOrder] = []
    @State private var isLoading = false
    @State private var selectedOrder: FrydgeOrder?
    @State private var showPayment = false
    @State private var terminalDiagnosticMessage: String?
    @State private var refreshTimer: Timer?
    @State private var lastNewCount = 0
    @State private var orderActionError: String?
    
    var newOrders: [FrydgeOrder] { orders.filter { $0.status == "pending" || $0.status == "pending_payment" } }
    var preparingOrders: [FrydgeOrder] { orders.filter { $0.status == "preparing" } }
    var readyOrders: [FrydgeOrder] { orders.filter { $0.status == "ready" } }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    if !newOrders.isEmpty {
                        Section {
                            ForEach(newOrders) { o in
                                OrderCard(order: o, onAdvance: { Task { await advance(o) } }, onCollect: { selectedOrder = o; showPayment = true })
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                            }
                        } header: { SectionHeader(title: "New Orders", count: newOrders.count, color: .orange) }
                    }
                    if !preparingOrders.isEmpty {
                        Section {
                            ForEach(preparingOrders) { o in
                                OrderCard(order: o, onAdvance: { Task { await advance(o) } }, onCollect: { selectedOrder = o; showPayment = true })
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                            }
                        } header: { SectionHeader(title: "Preparing", count: preparingOrders.count, color: .blue) }
                    }
                    if !readyOrders.isEmpty {
                        Section {
                            ForEach(readyOrders) { o in
                                OrderCard(order: o, onAdvance: { Task { await advance(o) } }, onCollect: { selectedOrder = o; showPayment = true })
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                            }
                        } header: { SectionHeader(title: "Ready", count: readyOrders.count, color: .green) }
                    }
                    if newOrders.isEmpty && preparingOrders.isEmpty && readyOrders.isEmpty && !isLoading {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundColor(.green)
                            Text("All caught up!").font(.title2.bold())
                            Text("New orders appear here").foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 80)
                    }
                }.padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(api.currentOrg?.name ?? "Orders")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { api.currentOrg = nil } label: { Image(systemName: "building.2") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if isLoading { ProgressView().scaleEffect(0.8) }
                        Button { Task { await checkTerminalToken() } } label: { Image(systemName: "wave.3.right.circle") }
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .refreshable { await load() }
            .sheet(isPresented: $showPayment) {
                if let o = selectedOrder {
                    TapToPayView(order: o) { success in
                        if success { Task { await load() } }
                        showPayment = false
                    }
                }
            }
            .alert("Terminal Token Check", isPresented: Binding(
                get: { terminalDiagnosticMessage != nil },
                set: { if !$0 { terminalDiagnosticMessage = nil } }
            )) {
                Button("OK", role: .cancel) { terminalDiagnosticMessage = nil }
            } message: {
                Text(terminalDiagnosticMessage ?? "")
            }
            .alert("Order Update Failed", isPresented: Binding(
                get: { orderActionError != nil },
                set: { if !$0 { orderActionError = nil } }
            )) {
                Button("OK", role: .cancel) { orderActionError = nil }
            } message: {
                Text(orderActionError ?? "")
            }
        }
        .task { await load(); startPolling() }
        .onDisappear { stopPolling() }
    }
    
    private func load() async {
        guard let orgId = api.currentOrg?.id else { return }
        isLoading = true
        do {
            let fetched = try await api.fetchOrders(orgId: orgId)
            let nc = fetched.filter { $0.status == "pending" || $0.status == "pending_payment" }.count
            if nc > lastNewCount && lastNewCount > 0 {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                AudioServicesPlaySystemSound(1007)
                let c = UNMutableNotificationContent()
                c.title = api.currentOrg?.name ?? "Frydge"
                c.body = nc == 1 ? "New order!" : "\(nc) new orders!"
                c.sound = .default
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            }
            lastNewCount = nc
            orders = fetched
        } catch {
            // Polls every 15s — log rather than alert so a flaky connection
            // doesn't spam the clerk; user-initiated actions do alert.
            print("[ClerkOrderBoard] Order fetch failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
    
    private func checkTerminalToken() async {
        let result = await api.checkConnectionTokenEndpoint()
        let trimmedBody = result.body.count > 500 ? String(result.body.prefix(500)) + "…" : result.body
        terminalDiagnosticMessage = "POST \(result.url.absoluteString)\nStatus: \(result.statusCode)\n\n\(trimmedBody)"
    }

    private func advance(_ order: FrydgeOrder) async {
        let next: String
        switch order.status {
        case "pending", "pending_payment": next = "preparing"
        case "preparing": next = "ready"
        case "ready": next = "done"
        default: return
        }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: next)
            await load()
        } catch {
            orderActionError = "Couldn't move the order to \"\(next)\": \(error.localizedDescription)"
        }
    }
    
    private func startPolling() { stopPolling(); refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { await load() } } }
    private func stopPolling() { refreshTimer?.invalidate(); refreshTimer = nil }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String; let count: Int; let color: Color
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(count)").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.15)).foregroundColor(color).clipShape(Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }
}

// MARK: - Order Card

struct OrderCard: View {
    let order: FrydgeOrder
    let onAdvance: () -> Void
    let onCollect: () -> Void
    
    var statusColor: Color {
        switch order.status {
        case "pending", "pending_payment": return .orange
        case "preparing": return .blue
        case "ready": return .green
        default: return .gray
        }
    }
    
    var advanceLabel: String {
        switch order.status {
        case "pending", "pending_payment": return "Accept"
        case "preparing": return "Mark Ready"
        default: return "Collected"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(order.displayNumber).font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Text(order.timeAgo).font(.caption).foregroundColor(.secondary)
            }
            Label(order.customerName ?? "Customer", systemImage: "person.fill").font(.subheadline.weight(.medium))
            if !order.orderItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(order.orderItems, id: \.name) { item in
                        HStack(spacing: 8) {
                            Text(item.emoji ?? "🛍️")
                            Text(item.qty > 1 ? "\(item.qty)× \(item.name)" : item.name).font(.subheadline)
                            Spacer()
                            Text("$\(String(format: "%.2f", item.price * Double(item.qty)))").font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10).background(Color(.secondarySystemGroupedBackground)).cornerRadius(8)
            }
            HStack {
                Text("$\(String(format: "%.2f", order.totalAmount))").font(.title3.bold())
                Spacer()
                Label(order.isPaid ? "Paid" : "Pay on Arrival", systemImage: order.isPaid ? "checkmark.seal.fill" : "clock.fill")
                    .font(.caption.bold()).foregroundColor(order.isPaid ? .green : .orange)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((order.isPaid ? Color.green : Color.orange).opacity(0.12)).clipShape(Capsule())
            }
            HStack(spacing: 10) {
                if !order.isPaid && order.status == "ready" {
                    Button(action: onCollect) {
                        Label("Tap to Pay", systemImage: "wave.3.right")
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(Color.green).cornerRadius(10)
                    }
                }
                if order.status != "done" {
                    Button(action: onAdvance) {
                        Text(advanceLabel).font(.subheadline.bold()).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(statusColor).cornerRadius(10)
                    }
                }
            }
        }
        .padding(16).background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(statusColor.opacity(0.3), lineWidth: 1.5))
    }
}

// MARK: - Tap to Pay View

struct TapToPayView: View {
    let order: FrydgeOrder
    let onComplete: (Bool) -> Void
    
    @StateObject private var terminal = TerminalManager.shared
    @State private var state: TapState = .ready
    @State private var errorMessage: String?
    
    enum TapState { case ready, connecting, waiting, processing, success, failed, entitlementPending }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                VStack(spacing: 8) {
                    Text("$\(String(format: "%.2f", order.totalAmount))")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                    Text("\(order.displayNumber) · \(order.customerName ?? "Customer")")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                VStack(spacing: 16) {
                    switch state {
                    case .ready:
                        stateView(icon: "wave.3.right.circle.fill", color: .blue, title: "Ready to collect", subtitle: "Tap below to start")
                    case .connecting:
                        ProgressView().scaleEffect(2).padding()
                        Text("Connecting...").font(.headline)
                    case .waiting:
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 80)).foregroundColor(.blue).symbolEffect(.pulse)
                        Text("Hold card near top of iPhone").font(.title2.bold())
                        Text("Card · Apple Pay · Google Pay · Apple Watch").foregroundColor(.secondary).multilineTextAlignment(.center)
                    case .processing:
                        ProgressView().scaleEffect(2).padding()
                        Text("Processing...").font(.headline)
                    case .success:
                        stateView(icon: "checkmark.circle.fill", color: .green, title: "Payment Successful!", subtitle: nil)
                    case .failed:
                        stateView(icon: "xmark.circle.fill", color: .red, title: "Payment Failed", subtitle: errorMessage)
                    case .entitlementPending:
                        stateView(
                            icon: "iphone.radiowaves.left.and.right",
                            color: .blue,
                            title: "Tap to Pay is linked",
                            subtitle: entitlementPendingMessage
                        )
                    }
                }
                .frame(maxWidth: .infinity).padding(28)
                .background(Color(.secondarySystemGroupedBackground)).cornerRadius(20).padding(.horizontal)
                Spacer()
                VStack(spacing: 12) {
                    if state == .ready || state == .failed {
                        Button { Task { await collect() } } label: {
                            Label(state == .failed ? "Try Again" : "Start Tap to Pay", systemImage: "wave.3.right")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.blue).cornerRadius(16)
                        }.padding(.horizontal)
                        Button("Cancel") { onComplete(false) }.foregroundColor(.secondary)
                    }
                    if state == .success {
                        Button { onComplete(true) } label: {
                            Text("Done").font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.green).cornerRadius(16)
                        }.padding(.horizontal)
                    }
                    if state == .entitlementPending {
                        Button { Task { await previewTapFlow() } } label: {
                            Label("Preview Tap Flow", systemImage: "wave.3.right")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.blue).cornerRadius(16)
                        }.padding(.horizontal)
                        Button("Close") { onComplete(false) }.foregroundColor(.secondary)
                    }
                }.padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Collect Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state == .ready {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { onComplete(false) } }
                }
            }
        }
    }
    
    @ViewBuilder
    private func stateView(icon: String, color: Color, title: String, subtitle: String?) -> some View {
        Image(systemName: icon).font(.system(size: 80)).foregroundColor(color)
        Text(title).font(.title2.bold()).foregroundColor(color)
        if let sub = subtitle { Text(sub).foregroundColor(.secondary).multilineTextAlignment(.center) }
    }
    
    private func collect() async {
        errorMessage = nil

        guard FrydgeAPIService.shared.authToken != nil else {
            state = .failed
            errorMessage = "Please sign in to Store Management again before using Tap to Pay. Stripe Terminal needs an authenticated connection token."
            return
        }

        do {
            try await terminal.collectPayment(amount: order.totalAmount, currency: "nzd", orderId: order.id) { newState in
                Task { @MainActor in state = newState }
            }
        } catch {
            if isTapToPayEntitlementPending(error) {
                state = .entitlementPending
                errorMessage = entitlementPendingMessage
            } else {
                state = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private var entitlementPendingMessage: String {
        "Order and Stripe are connected. Apple reader access is waiting on the Tap to Pay entitlement approval, so this preview does not capture a charge."
    }

    private func isTapToPayEntitlementPending(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("operation not permitted")
            || message.contains("necessary entitlements")
            || message.contains("application bundle is valid")
            || message.contains("proximity")
    }

    private func previewTapFlow() async {
        await MainActor.run {
            errorMessage = nil
            state = .waiting
        }
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await MainActor.run { state = .processing }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await MainActor.run {
            state = .entitlementPending
            errorMessage = entitlementPendingMessage
        }
    }
}

// MARK: - Deep-link Payment Router
//
// Gates `TapToPayDeepLinkView` behind a clerk login. Without this, the Stripe
// SDK initializes on mount and immediately calls `fetchConnectionToken` —
// which 401s because no JWT is attached when the deep link arrives cold.

struct DeepLinkPaymentRoot: View {
    let payment: PendingPayment
    let onComplete: (Bool) -> Void

    @ObservedObject private var api = FrydgeAPIService.shared

    var body: some View {
        if api.isLoggedIn {
            TapToPayDeepLinkView(payment: payment, onComplete: onComplete)
        } else {
            NavigationStack {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text("Sign in to take this payment")
                            .font(.headline)
                        Text("Order \(payment.orderId.prefix(6)) · $\(String(format: "%.2f", payment.amount))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()

                    ClerkLoginView()
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { onComplete(false) }
                    }
                }
            }
        }
    }
}

// MARK: - Deep-link Tap to Pay (frydge://collect)

/// Same UX as `TapToPayView` but driven directly by query params from a
/// `frydge://collect?orderId=&amount=&cs=…` URL. We already have the
/// clientSecret from the web side, so we skip the API call that creates one.
struct TapToPayDeepLinkView: View {
    let payment: PendingPayment
    let onComplete: (Bool) -> Void

    @State private var state: TapToPayView.TapState = .ready
    @State private var errorMessage: String?
    @State private var storeOptions: [FrydgeOrg] = []
    @State private var isLoadingStores = false
    @State private var isChoosingStore = false
    @State private var storeName: String?
    @State private var itemSummary: String?
    @State private var customerName: String?
    @State private var confirmedAmount: Double?
    @State private var animationPhase = false
    @State private var showConnectionHint = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                paymentSummaryHeader
                VStack(spacing: 16) {
                    switch state {
                    case .ready:
                        if isChoosingStore {
                            storeSelectionView
                        } else {
                            contactlessAnimation(systemName: "wave.3.right.circle.fill", color: .blue, isActive: true)
                            Text("Ready to collect").font(.title2.bold()).foregroundColor(.blue)
                            Text("Tap below to start").foregroundColor(.secondary)
                        }
                    case .connecting:
                        contactlessAnimation(systemName: "iphone.radiowaves.left.and.right", color: .blue, isActive: true)
                        Text("Connecting…").font(.headline)
                        if showConnectionHint {
                            Text("Still waiting for Stripe Terminal. Keep the app foregrounded. Saved location: \(StripeConfig.terminalLocationId.isEmpty ? "none" : StripeConfig.terminalLocationId). If this does not move, check that location belongs to this store's Stripe account.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    case .waiting:
                        contactlessAnimation(systemName: "iphone.radiowaves.left.and.right", color: .blue, isActive: true)
                        Text("Hold card near top of iPhone").font(.title2.bold())
                        Text("Card · Apple Pay · Google Pay · Apple Watch")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                    case .processing:
                        contactlessAnimation(systemName: "creditcard.fill", color: .orange, isActive: true)
                        Text("Processing…").font(.headline)
                    case .success:
                        contactlessAnimation(systemName: "checkmark.circle.fill", color: .green, isActive: false)
                        Text("Payment Successful!").font(.title2.bold()).foregroundColor(.green)
                    case .failed:
                        contactlessAnimation(systemName: "xmark.circle.fill", color: .red, isActive: false)
                        Text("Payment Failed").font(.title2.bold()).foregroundColor(.red)
                        if let m = errorMessage {
                            Text(m).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                    case .entitlementPending:
                        contactlessAnimation(systemName: "iphone.radiowaves.left.and.right", color: .blue, isActive: true)
                        Text("Tap to Pay is linked").font(.title2.bold()).foregroundColor(.blue)
                        Text(entitlementPendingMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity).padding(28)
                .background(Color(.secondarySystemGroupedBackground)).cornerRadius(20).padding(.horizontal)
                Spacer()
                VStack(spacing: 12) {
                    if (state == .ready || state == .failed) && !isChoosingStore {
                        Button { Task { await collect() } } label: {
                            Label(state == .failed ? "Try Again" : "Start Tap to Pay", systemImage: "wave.3.right")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.blue).cornerRadius(16)
                        }.padding(.horizontal)
                        Button("Cancel") { onComplete(false) }.foregroundColor(.secondary)
                    }
                    if state == .connecting {
                        Button("Close") { onComplete(false) }
                            .foregroundColor(.secondary)
                    }
                    if state == .success {
                        Button { onComplete(true) } label: {
                            Text("Done").font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.green).cornerRadius(16)
                        }.padding(.horizontal)
                    }
                    if state == .entitlementPending {
                        Button { Task { await previewTapFlow() } } label: {
                            Label("Preview Tap Flow", systemImage: "wave.3.right")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(Color.blue).cornerRadius(16)
                        }.padding(.horizontal)
                        Button("Close") { onComplete(false) }.foregroundColor(.secondary)
                    }
                }.padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Collect Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state == .ready {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { onComplete(false) } }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                animationPhase = true
            }
        }
        .onChange(of: state) { _, newState in
            if newState != .connecting {
                showConnectionHint = false
            }
        }
        .task(id: state) {
            guard state == .connecting else { return }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled && state == .connecting {
                showConnectionHint = true
            }
        }
    }

    private var paymentSummaryHeader: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("$\(String(format: "%.2f", confirmedAmount ?? payment.amount))")
                    .font(.system(size: 64, weight: .black, design: .rounded))

                Text(itemSummary ?? "Order \(payment.orderId.prefix(6))")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(summarySubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }

    private var summarySubtitle: String {
        let customer = customerName ?? payment.customerName
        switch (storeName, customer) {
        case let (store?, customer?):
            return "\(store) · \(customer)"
        case let (store?, nil):
            return store
        case let (nil, customer?):
            return customer
        case (nil, nil):
            return "Order \(payment.orderId.prefix(6))"
        }
    }

    private func contactlessAnimation(systemName: String, color: Color, isActive: Bool) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(isActive ? 0.18 : 0.08), lineWidth: 2)
                    .frame(width: CGFloat(94 + index * 28), height: CGFloat(94 + index * 28))
                    .scaleEffect(isActive && animationPhase ? 1.08 : 0.88)
                    .opacity(isActive ? (animationPhase ? 0.15 : 0.85) : 0.45)
                    .animation(
                        .easeInOut(duration: 1.15)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.14),
                        value: animationPhase
                    )
            }

            Circle()
                .fill(color.opacity(0.12))
                .frame(width: 96, height: 96)

            Image(systemName: systemName)
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(color)
                .symbolEffect(.pulse, options: isActive ? .repeating : .default, value: animationPhase)
        }
        .frame(width: 158, height: 132)
    }

    private var storeSelectionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 54))
                .foregroundColor(.blue)

            Text("Choose store")
                .font(.title2.bold())

            if isLoadingStores {
                ProgressView("Loading stores...")
            } else if storeOptions.isEmpty {
                Text(errorMessage ?? "No stores are available for this account.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: 8) {
                    ForEach(storeOptions) { org in
                        Button {
                            FrydgeAPIService.shared.selectOrg(org)
                            isChoosingStore = false
                            errorMessage = nil
                            Task { await collect() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(org.name)
                                        .font(.headline)
                                    Text(org.slug)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func collect() async {
        errorMessage = nil

        guard FrydgeAPIService.shared.authToken != nil else {
            state = .failed
            errorMessage = "Please sign in to Store Management again before using Tap to Pay. Stripe Terminal needs an authenticated connection token."
            return
        }

        do {
            let resolvedOrgId = try await FrydgeAPIService.shared.resolveTerminalPaymentOrgId(
                orderId: payment.orderId,
                explicitOrgId: payment.orgId
            )
            await enrichPaymentSummary(orgId: resolvedOrgId)
            FrydgeAPIService.shared.beginTerminalPayment(orgId: resolvedOrgId)
            defer { FrydgeAPIService.shared.endTerminalPayment() }

            try await TerminalManager.shared.collectPayment(
                amount: payment.amount,
                currency: "nzd",
                orderId: payment.orderId,
                orgId: resolvedOrgId,
                clientSecret: payment.clientSecret
            ) { newState in
                Task { @MainActor in state = newState }
            }
        } catch {
            if error.localizedDescription.contains("Payment link is missing store information") {
                await loadStoresForPayment()
            } else if isTapToPayEntitlementPending(error) {
                state = .entitlementPending
                errorMessage = entitlementPendingMessage
            } else {
                state = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private var entitlementPendingMessage: String {
        "Store, order, item, and Stripe connection are working. Apple reader access is waiting on the Tap to Pay entitlement approval, so this preview does not capture a charge."
    }

    private func isTapToPayEntitlementPending(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("operation not permitted")
            || message.contains("necessary entitlements")
            || message.contains("application bundle is valid")
            || message.contains("proximity")
    }

    private func previewTapFlow() async {
        await MainActor.run {
            errorMessage = nil
            state = .waiting
        }
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await MainActor.run { state = .processing }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await MainActor.run {
            state = .entitlementPending
            errorMessage = entitlementPendingMessage
        }
    }

    private func loadStoresForPayment() async {
        isLoadingStores = true
        isChoosingStore = true
        state = .ready
        errorMessage = nil

        do {
            let orgs = try await FrydgeAPIService.shared.fetchOrgs()
            storeOptions = orgs

            if orgs.count == 1, let org = orgs.first {
                FrydgeAPIService.shared.selectOrg(org)
                isChoosingStore = false
                isLoadingStores = false
                await collect()
                return
            }

            if orgs.isEmpty {
                errorMessage = "No stores are available for this account."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingStores = false
    }

    private func enrichPaymentSummary(orgId: String) async {
        if storeName == nil {
            if FrydgeAPIService.shared.currentOrg?.id == orgId {
                storeName = FrydgeAPIService.shared.currentOrg?.name
            } else if let org = storeOptions.first(where: { $0.id == orgId }) {
                storeName = org.name
            }
        }

        do {
            let orders = try await FrydgeAPIService.shared.fetchOrders(orgId: orgId)
            guard let order = orders.first(where: { $0.id == payment.orderId }) else { return }

            customerName = order.customerName
            confirmedAmount = order.total

            let items = order.orderItems
            if let first = items.first {
                if items.count == 1 {
                    itemSummary = first.qty > 1 ? "\(first.qty)x \(first.name)" : first.name
                } else {
                    itemSummary = "\(first.name) + \(items.count - 1) more"
                }
            }
        } catch {
            print("[PAY] Unable to enrich payment summary orderId=\(payment.orderId): \(error.localizedDescription)")
        }
    }
}
