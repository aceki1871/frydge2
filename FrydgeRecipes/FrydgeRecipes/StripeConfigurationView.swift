import SwiftUI

struct StripeConfigurationView: View {
    @State private var publishableKey: String = StripeConfig.publishableKey
    @State private var backendURL: String = StripeConfig.backendBaseURL
    @State private var terminalLocationId: String = StripeConfig.terminalLocationId
    @State private var showingSaved = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Configure Stripe to enable marketplace payments")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Publishable Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextField("pk_test_...", text: $publishableKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backend URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextField("https://your-server.com", text: $backendURL)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Terminal Location ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("tml_...", text: $terminalLocationId)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    Text("Stripe Settings")
                } footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Get your publishable key from the Stripe Dashboard")
                        
                        Link("Open Stripe Dashboard →", destination: URL(string: "https://dashboard.stripe.com/test/apikeys")!)
                            .font(.caption)
                    }
                }
                
                Section {
                    if StripeConfig.isConfigured {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Stripe is configured")
                            Spacer()
                        }
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Configuration incomplete")
                            Spacer()
                        }
                    }

                    HStack {
                        Image(systemName: StripeConfig.hasTerminalLocation ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(StripeConfig.hasTerminalLocation ? .green : .orange)
                        Text(StripeConfig.hasTerminalLocation ? "Terminal location saved" : "Terminal location missing")
                        Spacer()
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tap to Pay", systemImage: "wave.3.right")
                            .font(.headline)
                        
                        Text("For Tap to Pay on iPhone, you'll need:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            checklistItem("Stripe Terminal SDK", systemImage: "checkmark.circle")
                            checklistItem("Merchant account approval", systemImage: "building.columns")
                            checklistItem("Terminal location ID from the connected Stripe account", systemImage: "mappin.and.ellipse")
                            checklistItem("Device registration", systemImage: "iphone.radiowaves.left.and.right")
                        }
                        .padding(.leading)
                        
                        Link("Learn more about Tap to Pay →", 
                             destination: URL(string: "https://stripe.com/docs/terminal/payments/setup-reader/tap-to-pay")!)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Tap to Pay on iPhone")
                } footer: {
                    Text("The Terminal Location ID must be the tml_ value from the same Stripe account that issued this store's connection token. If Stripe stays on Connecting, this is the first value to check.")
                }
            }
            .navigationTitle("Payment Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveConfiguration()
                    }
                    .disabled(publishableKey.isEmpty || backendURL.isEmpty)
                }
            }
            .alert("Saved", isPresented: $showingSaved) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Stripe configuration has been saved")
            }
        }
    }
    
    private func checklistItem(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
        }
    }
    
    private func saveConfiguration() {
        StripeConfig.configure(
            publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines),
            backendURL: backendURL.trimmingCharacters(in: .whitespacesAndNewlines),
            terminalLocationId: terminalLocationId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        showingSaved = true
    }
}

#Preview {
    StripeConfigurationView()
}
