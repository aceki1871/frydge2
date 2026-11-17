//
//  QuickStripeSetup.swift
//  FrydgeRecipes
//
//  Quick setup helper for Stripe configuration
//

import SwiftUI

/// Quick setup view - Run this once to configure Stripe
struct QuickStripeSetup: View {
    // Your publishable key (already provided)
    private let publishableKey = "pk_test_51TSViXCVYZKUKvUzJnn2qkhypIB7txxKzub2bZylpgmKyLJ6WCckN7iyITlSRoLW4uAcrWadY7TzFbzCZxs6c2ye00PHo3E4tG"
    
    @State private var backendURL = ""
    @State private var terminalLocationId = StripeConfig.terminalLocationId
    @State private var useLocalBackend = false
    @State private var showSuccess = false
    @State private var isConfigured = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                // Status
                Section {
                    HStack {
                        Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(isConfigured ? .green : .orange)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isConfigured ? "Stripe Configured" : "Setup Required")
                                .font(.headline)
                            Text(isConfigured ? "Ready to accept payments" : "Complete setup to enable payments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Image(systemName: StripeConfig.hasTerminalLocation ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(StripeConfig.hasTerminalLocation ? .green : .orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(StripeConfig.hasTerminalLocation ? "Tap to Pay Location Saved" : "Tap to Pay Location Needed")
                                .font(.headline)
                            Text(StripeConfig.hasTerminalLocation ? StripeConfig.terminalLocationId : "Add the tml_ Terminal location from Stripe")
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                
                // Publishable Key (Read-only, already set)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Publishable Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        
                        Text(publishableKey)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("✅ Your publishable key is ready to use")
                }
                
                // Backend Setup Options
                Section {
                    // DEBUG only. This toggle used to ship in release builds,
                    // offering users a cleartext http://localhost:3000 backend.
                    #if DEBUG
                    Toggle("Use Local Test Backend", isOn: $useLocalBackend)
                    #endif
                    
                    #if DEBUG
                    if useLocalBackend {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(Self.localTestBackend)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.blue)

                            Text("For testing with local backend server")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    #endif

                    // `useLocalBackend` can only ever be true in a DEBUG build, so
                    // release always shows the production field.
                    if !useLocalBackend {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Production Backend URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField(StripeConfig.defaultBackendBaseURL, text: $backendURL)
                                .textFieldStyle(.roundedBorder)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } header: {
                    Text("Backend Server")
                } footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        if useLocalBackend {
                            Text("⚠️ Make sure your local backend is running on port 3000")
                            
                            Text("To start the backend:")
                                .fontWeight(.medium)
                            
                            Text("1. cd to backend folder\n2. npm install\n3. node stripe-backend-example.js")
                                .font(.caption)
                                .fontDesign(.monospaced)
                        } else {
                            Text("Deploy the backend server to Vercel, Railway, or any hosting service")
                            
                            Link("📖 See deployment guide", destination: URL(string: "file:///PAYMENT_SETUP_GUIDE.md")!)
                                .font(.caption)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Terminal Location ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("tml_...", text: $terminalLocationId)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    Text("Tap to Pay")
                } footer: {
                    Text("Use the tml_ location from the same Stripe account as the store connection token. If the app stays on Connecting, check this value first.")
                }
                
                // Quick Deploy Options
                Section {
                    Link(destination: URL(string: "https://vercel.com/new")!) {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Deploy to Vercel")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                    
                    Link(destination: URL(string: "https://railway.app/new")!) {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Deploy to Railway")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Quick Deploy")
                } footer: {
                    Text("Both platforms offer free tiers for testing")
                }
                
                // Save Button
                Section {
                    Button {
                        saveConfiguration()
                    } label: {
                        HStack {
                            Spacer()
                            if isConfigured {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(isConfigured ? "Configuration Saved" : "Save Configuration")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Stripe Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isConfigured {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                checkConfiguration()
                #if DEBUG
                if useLocalBackend {
                    backendURL = Self.localTestBackend
                }
                #endif
            }
            .onChange(of: useLocalBackend) { _, newValue in
                #if DEBUG
                if newValue {
                    backendURL = Self.localTestBackend
                }
                #endif
            }
            .alert("Setup Complete!", isPresented: $showSuccess) {
                Button("Done") {
                    dismiss()
                }
            } message: {
                Text("Stripe is now configured and ready to accept payments")
            }
        }
    }
    
    private var canSave: Bool {
        !backendURL.isEmpty
    }
    
    private func checkConfiguration() {
        isConfigured = StripeConfig.isConfigured
        // backendBaseURL now resolves to the deployed worker by default, so
        // prefill it always rather than only when already configured.
        backendURL = StripeConfig.backendBaseURL
        terminalLocationId = StripeConfig.terminalLocationId
    }
    
    #if DEBUG
    /// Local dev backend. Debug-only — never reachable in a release build.
    static let localTestBackend = "http://localhost:3000"
    #endif

    private func saveConfiguration() {
        #if DEBUG
        let finalURL = useLocalBackend ? Self.localTestBackend : backendURL
        #else
        let finalURL = backendURL
        #endif
        
        StripeConfig.configure(
            publishableKey: publishableKey,
            backendURL: finalURL,
            terminalLocationId: terminalLocationId
        )
        
        isConfigured = true
        showSuccess = true
    }
}

// MARK: - Simple Test View

/// Use this to test if Stripe is configured correctly
struct StripeTestView: View {
    @State private var testAmount = "10.00"
    @State private var isTesting = false
    @State private var testResult = ""
    @State private var showResult = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if StripeConfig.isConfigured {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Stripe is configured")
                        }
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Stripe not configured")
                        }
                    }
                } header: {
                    Text("Status")
                }
                
                Section {
                    HStack {
                        Text("Publishable Key:")
                        Spacer()
                        Text(StripeConfig.isConfigured ? "Set ✓" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Backend URL:")
                        Spacer()
                        Text(StripeConfig.isConfigured ? "Set ✓" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                    
                    if StripeConfig.isConfigured {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backend:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(StripeConfig.backendBaseURL)
                                .font(.caption)
                                .fontDesign(.monospaced)
                        }
                    }
                } header: {
                    Text("Configuration")
                }
                
                if StripeConfig.isConfigured {
                    Section {
                        HStack {
                            Text("$")
                            TextField("Amount", text: $testAmount)
                                .keyboardType(.decimalPad)
                        }
                        
                        Button {
                            testPaymentIntent()
                        } label: {
                            HStack {
                                Spacer()
                                if isTesting {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                }
                                Text(isTesting ? "Testing..." : "Test Payment Intent")
                                Spacer()
                            }
                        }
                        .disabled(isTesting || testAmount.isEmpty)
                    } header: {
                        Text("Test Backend Connection")
                    } footer: {
                        Text("This will test creating a PaymentIntent without charging anything")
                    }
                }
            }
            .navigationTitle("Stripe Test")
            .alert("Test Result", isPresented: $showResult) {
                Button("OK") { }
            } message: {
                Text(testResult)
            }
        }
    }
    
    private func testPaymentIntent() {
        guard let amount = Double(testAmount) else { return }
        
        isTesting = true
        
        Task {
            do {
                let amountInCents = Int(amount * 100)
                let response = try await StripeBackendService.shared.createPaymentIntent(
                    amount: amountInCents,
                    currency: "nzd",
                    metadata: ["test": "true"]
                )
                
                await MainActor.run {
                    testResult = """
                    ✅ Success!
                    
                    PaymentIntent created successfully.
                    
                    Client Secret: \(response.clientSecret.prefix(20))...
                    
                    Your backend is working correctly!
                    """
                    isTesting = false
                    showResult = true
                }
            } catch {
                await MainActor.run {
                    testResult = """
                    ❌ Failed
                    
                    \(error.localizedDescription)
                    
                    Check that:
                    • Backend server is running
                    • Backend URL is correct
                    • Secret key is set on backend
                    """
                    isTesting = false
                    showResult = true
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Setup") {
    QuickStripeSetup()
}

#Preview("Test") {
    StripeTestView()
}
