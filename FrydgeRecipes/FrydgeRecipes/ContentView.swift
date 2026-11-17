//
//  ContentView.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/10/2024.
//

import SwiftUI
import AuthenticationServices
import CloudKit
import PhotosUI

extension Notification.Name {
    /// Posted from Profile → Log Out to return the user to the welcome screen.
    static let frydgeDidLogout = Notification.Name("frydgeDidLogout")
}

struct ContentView: View {
    @AppStorage("hasCompletedInitialAppleLink") private var hasCompletedInitialAppleLink = false
    // Sign in with Apple is optional (App Review 5.1.1(v)): the user can skip it
    // at launch and is offered it again only when they start a sharing action.
    @AppStorage("hasSkippedInitialAppleLink") private var hasSkippedInitialAppleLink = false
    @AppStorage("hasCompletedProfileSetup") private var hasCompletedProfileSetup = false
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @State private var loggedIn = false
    @State private var showSignInWithApple = false
    @State private var firstName: String = ""
    @State private var cloudKitStatus: String = "Unknown CloudKit Status"
    @State private var cloudKitError: String?
    @State private var retryCount = 0
    @State private var showReAuthAlert = false

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var invites: PendingInvites

    let maxRetries = 5

    var body: some View {
        VStack {
            if shouldRequireInitialAppleLink {
                VStack {
                    Spacer()

                    Text("Welcome to Frydge")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding()

                    Text("Track your fridge, plan meals and shop smarter. Your data stays in your iCloud account.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 32)

                    if showSignInWithApple {
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                request.requestedScopes = [.fullName, .email]
                            },
                            onCompletion: { result in
                                handleSignIn(result: result)
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(width: 220, height: 45)
                        .padding()

                        Button("Continue without an account") {
                            hasSkippedInitialAppleLink = true
                            loggedIn = true
                            showSignInWithApple = false
                            cloudKitError = nil
                        }
                        .font(.subheadline)
                    }

                    if let error = cloudKitError, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Spacer()
                }
            } else if !hasCompletedProfileSetup {
                ProfileSetupView {
                    hasCompletedProfileSetup = true
                }
            } else {
                MainTabView()
                    .environmentObject(appState)
                    .fullScreenCover(isPresented: showTutorial) {
                        TutorialView {
                            hasSeenTutorial = true
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .frydgeDidLogout)) { _ in
            // Log Out (from Profile) already cleared the persisted gate flags; mirror
            // that into local state and re-show the Sign in with Apple button.
            loggedIn = false
            showReAuthAlert = false
            showSignInWithApple = true
        }
        .alert(isPresented: $showReAuthAlert) {
            Alert(
                title: Text("Re-authentication Required"),
                message: Text("You need to sign in with Apple again to access CloudKit."),
                primaryButton: .default(Text("Re-authenticate"), action: {
                    self.showSignInWithApple = true
                }),
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
        .onAppear {
            showSignInWithApple = shouldRequireInitialAppleLink || showReAuthAlert

            if hasCompletedInitialAppleLink {
                loggedIn = true
                // Check CloudKit status in the background — don't block the UI
                Task {
                    await checkCloudKitAccountStatus()
                }
            }

            if !invites.metas.isEmpty {
                print("[INVITES] ContentView appeared with pending invites count=\(invites.metas.count)")
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var shouldRequireInitialAppleLink: Bool {
        !hasCompletedInitialAppleLink && !hasSkippedInitialAppleLink && !loggedIn
    }

    /// Presents the tutorial exactly once, the first time the main app appears.
    /// Dismissing the cover (swipe or Skip/Get Started) marks it as seen.
    private var showTutorial: Binding<Bool> {
        Binding(
            get: { !hasSeenTutorial },
            set: { isPresented in
                if !isPresented { hasSeenTutorial = true }
            }
        )
    }

    private func handleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authResults):
            if let appleIDCredential = authResults.credential as? ASAuthorizationAppleIDCredential {
                let fullName = appleIDCredential.fullName
                persistAppleIdentity(from: appleIDCredential)
                self.firstName = fullName?.givenName ?? "User"
                self.loggedIn = true
                self.hasCompletedInitialAppleLink = true
                self.showSignInWithApple = false
                self.cloudKitError = nil
                Task { await checkCloudKitAccountStatus() }
            }
        case .failure(let error):
            print("[FRYDGE] Authorization failed: \(error.localizedDescription)")
            self.cloudKitError = error.localizedDescription
            self.showSignInWithApple = true
        }
    }

    private func persistAppleIdentity(from credential: ASAuthorizationAppleIDCredential) {
        AppleSignInGate.persist(credential: credential)
    }

    private func checkCloudKitAccountStatus() async {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                await MainActor.run {
                    cloudKitError = nil
                    loggedIn = hasCompletedInitialAppleLink
                }
                // Verify container access in the background after UI is already visible
                await checkContainerAccess(container)
            case .noAccount:
                cloudKitStatus = "No iCloud account found."
                cloudKitError = "Sign in to iCloud again to reconnect Frydge."
                loggedIn = false
                showReAuthAlert = true
                showSignInWithApple = true
            case .restricted, .couldNotDetermine:
                cloudKitStatus = "CloudKit access restricted."
                cloudKitError = "Cloud access is currently unavailable."
                await retryFetchCloudKitStatus()
            case .temporarilyUnavailable:
                cloudKitStatus = "CloudKit service unavailable."
                cloudKitError = "CloudKit is temporarily unavailable."
                await retryFetchCloudKitStatus()
            @unknown default:
                cloudKitStatus = "Unknown CloudKit status."
            }
        } catch {
            cloudKitError = error.localizedDescription
            await retryFetchCloudKitStatus()
        }
    }

    private func retryFetchCloudKitStatus() async {
        retryCount += 1
        guard retryCount <= maxRetries else {
            cloudKitStatus = "Max retry attempts reached."
            return
        }
        let delayTime = Double(retryCount) * 2.0
        try? await Task.sleep(nanoseconds: UInt64(delayTime * 1_000_000_000))
        await checkCloudKitAccountStatus()
    }

    private func checkContainerAccess(_ container: CKContainer) async {
        do {
            let query = CKQuery(recordType: "Recipe", predicate: NSPredicate(value: true))
            // Fetch just 1 record to verify access without downloading everything
            let (_, _) = try await container.publicCloudDatabase.records(matching: query, resultsLimit: 1)
            await MainActor.run {
                cloudKitStatus = "Connected"
                cloudKitError = nil
                showReAuthAlert = false
                showSignInWithApple = false
            }
        } catch {
            await MainActor.run {
                // Only a genuine auth failure should send the user back to
                // sign-in. Anything else here is a network blip — the app works
                // offline from its local cache, and the "Re-authentication
                // Required" alert was a dead end (its button only affects the
                // welcome screen, which isn't on screen at this point).
                if let ck = error as? CKError, ck.code == .notAuthenticated {
                    cloudKitError = "Sign in to iCloud to sync Frydge."
                    loggedIn = false
                    showReAuthAlert = true
                    showSignInWithApple = true
                } else {
                    cloudKitStatus = "Offline"
                    print("[CK] Container check failed, carrying on offline: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - First-run Profile Setup

/// One-time step shown right after the initial Sign in with Apple. Captures the
/// user's name (pre-filled from their Apple identity when available) and an
/// optional profile photo, persisting both to the same keys the Profile screen
/// uses so they're saved and shown everywhere.
private struct ProfileSetupView: View {
    @AppStorage("frydge.authorName") private var profileName = ""
    @AppStorage("frydge.profileAvatar") private var avatarData = Data()

    @State private var nameField = ""
    @State private var avatarItem: PhotosPickerItem?

    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("Set up your profile")
                .font(.largeTitle.bold())
            Text("This is how you'll appear on recipes you create and share. You can change it any time in Profile.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                avatar
            }
            .buttonStyle(.plain)

            TextField("Your name", text: $nameField)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // The most important dietary rules, up front. Anything more
            // specific lives in Profile → Dietary → Can't & won't eat.
            VStack(alignment: .leading, spacing: 8) {
                Text("Anything you can't eat?")
                    .font(.subheadline.weight(.semibold))
                Text("Frydge will warn you when you scan or add it. Add more detail any time in Profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DietaryQuickPicks()
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                let trimmed = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
                profileName = trimmed
                RecipeAuthor.setName(trimmed)
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .disabled(nameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Skip for now") { onContinue() }
                .font(.subheadline)
                .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            if nameField.isEmpty { nameField = prefilledName }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await loadAvatar(from: item) }
        }
    }

    private var avatar: some View {
        ZStack {
            if let image = UIImage.frydgeBounded(data: avatarData, maxPixelSize: ImageBudget.thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 110, height: 110)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: "camera.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
                .background(Circle().fill(Color(.systemBackground)))
        }
        .accessibilityLabel("Add a profile picture")
    }

    /// Prefer any name the user already set, else the name Apple gave us at sign-in.
    private var prefilledName: String {
        let existing = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return existing }
        let defaults = UserDefaults.standard
        let given = defaults.string(forKey: "appleGivenName") ?? ""
        let family = defaults.string(forKey: "appleFamilyName") ?? ""
        return [given, family].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func loadAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail) else { return }
        let thumbnail = image.frydgeAvatarThumbnail(maxDimension: 256)
        if let jpeg = thumbnail.jpegData(compressionQuality: 0.8) {
            await MainActor.run { avatarData = jpeg }
        }
    }
}
