//
//  AppleSignInGate.swift
//  FrydgeRecipes
//
//  Sign in with Apple is optional. Fridge, recipes and shopping lists work off
//  the device's iCloud account, so the app never blocks on an Apple ID link.
//  The one place a link genuinely helps is sharing: household members and
//  marketplace buyers see the user's name. So the first time someone starts a
//  sharing action (create a shared frydge/list, list an item for sale) we offer
//  the link once, with a clear "Not now" that continues straight into the action.
//

import SwiftUI
import AuthenticationServices

enum AppleSignInGate {
    static let linkedKey = "hasCompletedInitialAppleLink"
    static let skippedAtLaunchKey = "hasSkippedInitialAppleLink"
    static let declinedSharingPromptKey = "hasDeclinedSharingSignInPrompt"

    static var hasLinkedAppleID: Bool {
        UserDefaults.standard.bool(forKey: linkedKey)
    }

    /// True when we should offer the link before a sharing action: never linked,
    /// and the user hasn't already said "Not now" to this prompt.
    static var shouldOfferBeforeSharing: Bool {
        !hasLinkedAppleID && !UserDefaults.standard.bool(forKey: declinedSharingPromptKey)
    }

    /// Stores the name and email Apple hands back (only on the first sign-in) and
    /// marks the link complete. Shared by the welcome screen and the sharing prompt.
    static func persist(credential: ASAuthorizationAppleIDCredential) {
        let defaults = UserDefaults.standard
        if let givenName = credential.fullName?.givenName, !givenName.isEmpty {
            defaults.set(givenName, forKey: "appleGivenName")
        }
        if let familyName = credential.fullName?.familyName, !familyName.isEmpty {
            defaults.set(familyName, forKey: "appleFamilyName")
        }
        if let email = credential.email, !email.isEmpty {
            defaults.set(email, forKey: "appleEmail")
        }
        defaults.set(true, forKey: linkedKey)
    }

    /// Clears every flag so the welcome screen shows again (Profile → Log Out).
    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: linkedKey)
        defaults.set(false, forKey: skippedAtLaunchKey)
        defaults.set(false, forKey: declinedSharingPromptKey)
    }
}

/// One-time offer to link an Apple ID before a sharing action. Both outcomes
/// (linked or "Not now") call `onContinue` so the action the user tapped
/// proceeds either way.
struct AppleSignInPromptSheet: View {
    /// What the user is about to do, e.g. "create a shared frydge".
    var actionDescription: String
    var onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text("Add your name?")
                    .font(.title2.bold())

                Text("You're about to \(actionDescription). Signing in with Apple lets the people you share with see who you are. It's optional — you can carry on without it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                            AppleSignInGate.persist(credential: credential)
                        }
                        finish()
                    case .failure(let error):
                        // Cancelling the Apple sheet isn't an error worth showing.
                        if (error as? ASAuthorizationError)?.code != .canceled {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 48)
                .padding(.horizontal, 28)

                Button("Not now") {
                    UserDefaults.standard.set(true, forKey: AppleSignInGate.declinedSharingPromptKey)
                    finish()
                }
                .font(.subheadline)
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func finish() {
        dismiss()
        // Let this sheet finish dismissing before the caller presents its own.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onContinue()
        }
    }
}
