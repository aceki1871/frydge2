//
//  FrydgeAPIService.swift
//  FrydgeRecipes
//
//  Handles communication with the Frydge backend API
//

import Foundation

// MARK: - Models

struct FrydgeOrder: Identifiable, Codable {
    let id: String
    var orderNum: Int?
    let venueId: String?
    let customerName: String?
    let customerPhone: String?
    var status: String
    let total: Double?
    let paymentMethod: String?
    let itemsJson: String?
    let createdAt: Double?
    
    var orderItems: [OrderItem] {
        guard let json = itemsJson,
              let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([OrderItem].self, from: data)
        else { return [] }
        return items
    }
    
    var totalAmount: Double { total ?? 0 }
    var displayNumber: String { "#\(orderNum ?? Int(id.suffix(4), radix: 16) ?? 0)" }
    var isPaid: Bool { paymentMethod == "online" || status == "paid" }
    
    var timeAgo: String {
        guard let ts = createdAt else { return "" }
        let mins = Int((Date().timeIntervalSince1970 * 1000 - ts) / 60000)
        if mins < 1 { return "Just now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins/60)h ago"
    }
    
    enum CodingKeys: String, CodingKey {
        case id, status, total
        case orderNum = "order_num"
        case venueId = "venue_id"
        case customerName = "customer_name"
        case customerPhone = "customer_phone"
        case paymentMethod = "payment_method"
        case itemsJson = "items_json"
        case createdAt = "created_at"
    }
}

struct OrderItem: Codable {
    let id: String?
    let name: String
    let price: Double
    let qty: Int
    let emoji: String?
}

struct FrydgeOrg: Identifiable, Codable {
    let id: String
    let name: String
    let slug: String
    let logoUrl: String?
    let brandColour: String?
    let currency: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case logoUrl = "logo_url"
        case brandColour = "brand_colour"
        case currency
    }
}

struct TerminalConnectionTokenResponse: Codable {
    let secret: String
}

struct TerminalConnectionTokenDiagnostic {
    let url: URL
    let statusCode: Int
    let body: String
}

private struct TerminalConnectionTokenRequest: Codable {
    let orgId: String
}

struct TerminalPaymentIntentResponse: Codable {
    let clientSecret: String
    let paymentIntentId: String
}

// MARK: - API Service

@MainActor
class FrydgeAPIService: ObservableObject {
    static let shared = FrydgeAPIService()
    
    let baseURL = "https://login.frydge2.com"
    
    /// Keychain key for the Clerk bearer token. A credential belongs in the
    /// Keychain, not UserDefaults (which is plain-text in the app container
    /// and included in unencrypted backups).
    private static let tokenKey = "frydge_clerk_token"

    @Published var authToken: String? {
        didSet {
            KeychainStore.set(authToken, for: Self.tokenKey)
        }
    }
    @Published var currentOrg: FrydgeOrg?
    @Published var isLoggedIn = false
    private var terminalPaymentOrgId: String?
    
    init() {
        // One-time migration: earlier builds kept the token in UserDefaults.
        if let legacy = UserDefaults.standard.string(forKey: Self.tokenKey) {
            KeychainStore.set(legacy, for: Self.tokenKey)
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
        authToken = KeychainStore.string(for: Self.tokenKey)
        isLoggedIn = authToken != nil
    }
    
    // MARK: - Auth
    
    func login(email: String, password: String) async throws {
        struct LoginRequest: Codable { let email: String; let password: String }
        struct LoginResponse: Codable { let token: String }
        
        let body = LoginRequest(email: email, password: password)
        let response: LoginResponse = try await post("/api/auth/email", body: body)
        authToken = response.token
        isLoggedIn = true
    }

    func loginWithApple(identityToken: String, authorizationCode: String?, fullName: String?) async throws {
        struct AppleLoginRequest: Codable {
            let identityToken: String
            let authorizationCode: String?
            let fullName: String?
        }
        struct LoginResponse: Codable { let token: String }

        let body = AppleLoginRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName
        )
        let response: LoginResponse = try await post("/api/auth/apple", body: body)
        authToken = response.token
        isLoggedIn = true
    }
    
    func logout() {
        authToken = nil
        isLoggedIn = false
        currentOrg = nil
        KeychainStore.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: "frydge_clerk_orgId")
    }
    
    // MARK: - Orgs
    
    func fetchOrgs() async throws -> [FrydgeOrg] {
        return try await get("/api/super-admin/orgs")
    }
    
    func selectOrg(_ org: FrydgeOrg) {
        currentOrg = org
        UserDefaults.standard.set(org.id, forKey: "frydge_clerk_orgId")
    }
    
    func loadSavedOrg() async {
        guard let orgId = UserDefaults.standard.string(forKey: "frydge_clerk_orgId") else { return }
        do {
            let org: FrydgeOrg = try await get("/api/super-admin/orgs/\(orgId)")
            currentOrg = org
        } catch {}
    }
    
    // MARK: - Orders
    
    func fetchOrders(orgId: String) async throws -> [FrydgeOrder] {
        return try await get("/api/orders?orgId=\(orgId)")
    }

    func updateOrderStatus(orderId: String, status: String) async throws {
        struct UpdateRequest: Codable { let status: String }
        let _: EmptyResponse = try await patch("/api/orders/\(orderId)", body: UpdateRequest(status: status))
    }

    func beginTerminalPayment(orgId: String?) {
        terminalPaymentOrgId = orgId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func endTerminalPayment() {
        terminalPaymentOrgId = nil
    }

    func resolveTerminalPaymentOrgId(orderId: String, explicitOrgId: String?) async throws -> String {
        if let explicitOrgId = explicitOrgId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitOrgId.isEmpty {
            print("[PAY] Resolved payment org from link orgId=\(explicitOrgId) orderId=\(orderId)")
            return explicitOrgId
        }

        if let selectedOrgId = currentOrg?.id.trimmingCharacters(in: .whitespacesAndNewlines), !selectedOrgId.isEmpty {
            print("[PAY] Resolved payment org from selected store orgId=\(selectedOrgId) orderId=\(orderId)")
            return selectedOrgId
        }

        if let savedOrgId = UserDefaults.standard.string(forKey: "frydge_clerk_orgId")?.trimmingCharacters(in: .whitespacesAndNewlines), !savedOrgId.isEmpty {
            print("[PAY] Resolved payment org from saved store orgId=\(savedOrgId) orderId=\(orderId)")
            return savedOrgId
        }

        print("[PAY] Unable to resolve payment org orderId=\(orderId); collect URL did not include orgId/venueId/storeId")
        throw APIError.serverError("Payment link is missing store information. Checkout must include orgId, venueId, or storeId.")
    }
    
    // MARK: - Stripe Terminal
    
    func fetchConnectionToken() async throws -> String {
        let orgId = try terminalOrgId()
        let tokenPreview: String
        if let t = authToken, !t.isEmpty {
            tokenPreview = "\(t.prefix(8))…\(t.suffix(6)) (len=\(t.count))"
        } else {
            tokenPreview = "<nil>"
        }
        print("[TERMINAL] fetchConnectionToken orgId=\(orgId) authToken=\(tokenPreview)")
        do {
            let response: TerminalConnectionTokenResponse = try await terminalPost(
                "/api/stripe/terminal/connection-token",
                body: TerminalConnectionTokenRequest(orgId: orgId)
            )
            print("[TERMINAL] connection-token OK (secret prefix=\(response.secret.prefix(8))…)")
            return response.secret
        } catch {
            let diag = await checkConnectionTokenEndpoint()
            let bodyPreview = String(diag.body.prefix(400))
            print("[TERMINAL] connection-token FAILED. status=\(diag.statusCode) body=\(bodyPreview)")
            throw error
        }
    }

    func checkConnectionTokenEndpoint() async -> TerminalConnectionTokenDiagnostic {
        guard let url = URL(string: baseURL + "/api/stripe/terminal/connection-token") else {
            return TerminalConnectionTokenDiagnostic(url: URL(string: baseURL)!, statusCode: 0, body: "Invalid URL")
        }
        let orgId: String
        do {
            orgId = try terminalOrgId()
        } catch {
            return TerminalConnectionTokenDiagnostic(url: url, statusCode: 0, body: error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(TerminalConnectionTokenRequest(orgId: orgId))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            return TerminalConnectionTokenDiagnostic(url: url, statusCode: status, body: body)
        } catch {
            return TerminalConnectionTokenDiagnostic(url: url, statusCode: 0, body: error.localizedDescription)
        }
    }
    
    func createTerminalPaymentIntent(amount: Double, orderId: String) async throws -> TerminalPaymentIntentResponse {
        struct Request: Codable { let amount: Double; let currency: String; let orderId: String }
        return try await post("/api/stripe/terminal/payment-intent", body: Request(amount: amount, currency: "nzd", orderId: orderId))
    }
    
    // MARK: - HTTP helpers
    
    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data, path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data, path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    private func terminalPost<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data, logsOutOnUnauthorized: false, path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func terminalOrgId() throws -> String {
        let orgId = terminalPaymentOrgId ?? currentOrg?.id ?? UserDefaults.standard.string(forKey: "frydge_clerk_orgId")
        guard let orgId = orgId?.trimmingCharacters(in: .whitespacesAndNewlines), !orgId.isEmpty else {
            throw APIError.serverError("This payment link is missing store information. Reopen the payment from checkout.")
        }
        return orgId
    }

    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data, path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    private func checkResponse(_ response: URLResponse, data: Data, logsOutOnUnauthorized: Bool = true, path: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 {
            if logsOutOnUnauthorized {
                logout()
            }
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let rawBody = String(data: data, encoding: .utf8)
            let msg = decoded?.message ?? decoded?.error ?? rawBody ?? "Error \(http.statusCode)"
            let route = path.map { " \($0)" } ?? ""
            throw APIError.serverError("HTTP \(http.statusCode)\(route): \(msg)")
        }
    }
}

struct EmptyResponse: Codable {}
struct APIErrorResponse: Codable {
    let error: String?
    let message: String?
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Please sign in again"
        case .serverError(let msg): return msg
        }
    }
}
