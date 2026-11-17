import SwiftUI
import CloudKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import AuthenticationServices

// MARK: - ProfileView

struct ProfileView: View {
    @StateObject private var vm = ProfileViewModel()
    @ObservedObject private var dietaryRestrictions = DietaryRestrictionStore.shared
    @EnvironmentObject var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject var sharedFridgeManager: SharedFridgeManager
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @ObservedObject private var marketplace = MarketplaceAvailability.shared

    @AppStorage("frydge.authorName") private var profileName = ""
    @AppStorage("frydge.profileDietary") private var profileDietaryCSV = ""
    @AppStorage("frydge.profileAvatar") private var avatarData = Data()
    @AppStorage(StoreArrivalReminders.key) private var storeArrivalRemindersEnabled = false
    @AppStorage(FrydgeIntelligence.enabledKey) private var appleIntelligenceEnabled = true
    @AppStorage(AppleSignInGate.linkedKey) private var hasLinkedAppleID = false
    @AppStorage(GroceryBudget.amountKey) private var budgetAmount: Double = 0
    @AppStorage(GroceryBudget.periodKey) private var budgetPeriodRaw: String = BudgetPeriod.weekly.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showLogoutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var deleteResultMessage: String?
    @State private var showSpending = false
    @State private var showLegal = false
    @State private var showTutorial = false

    /// Which shop the app currently thinks we're in (geofence, notification
    /// tap, or the manual picker below).
    @ObservedObject private var inStoreSession = InStoreSession.shared

    /// The "Shopping at" picker: "" = automatic (no manual override). Picking
    /// a chain starts a manual session; picking Automatic only clears a
    /// session that was itself manual, so it never cancels a real arrival.
    private var manualStoreSelection: Binding<String> {
        Binding(
            get: {
                guard let store = inStoreSession.current, store.source == .manual else { return "" }
                return store.chainKey
            },
            set: { key in
                if key.isEmpty {
                    if inStoreSession.current?.source == .manual {
                        inStoreSession.end()
                    }
                } else {
                    inStoreSession.begin(storeName: StoreChain.displayName(forKey: key), source: .manual)
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {

                // MARK: Account
                Section {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $avatarPickerItem, matching: .images, photoLibrary: .shared()) {
                            avatarView
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Your name", text: $profileName)
                                .font(.title2.weight(.semibold))
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .onSubmit { RecipeAuthor.setName(profileName) }
                                .onChange(of: profileName) { _, newValue in
                                    RecipeAuthor.setName(newValue)
                                }

                            if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(vm.profileDisplayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: vm.isICloudAvailable ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                                    .font(.caption)
                                    .foregroundStyle(vm.isICloudAvailable ? .green : .orange)
                                Text(vm.accountStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if vm.isLoading {
                            ProgressView().scaleEffect(0.9)
                        }
                    }
                    .padding(.vertical, 6)

                    // Optional Apple ID link for people who skipped it at launch.
                    // Only supplies a name/email; nothing else depends on it.
                    if !hasLinkedAppleID {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sign in with Apple to fill in your name for recipes and shared lists. Optional.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SignInWithAppleButton(.signIn) { request in
                                request.requestedScopes = [.fullName, .email]
                            } onCompletion: { result in
                                if case .success(let auth) = result,
                                   let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                                    AppleSignInGate.persist(credential: credential)
                                    seedProfileNameIfNeeded()
                                }
                            }
                            .signInWithAppleButtonStyle(.black)
                            .frame(height: 44)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Account")
                }

                // MARK: Dietary
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Dietary preferences", systemImage: "leaf")
                        HStack(spacing: 8) {
                            ForEach(["GF", "DF", "V", "VG"], id: \.self) { tag in
                                let isOn = selectedDietary.contains(tag)
                                Button {
                                    toggleDietary(tag)
                                } label: {
                                    Text(tag)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(isOn ? Color.green : Color(.tertiarySystemFill))
                                        )
                                        .foregroundStyle(isOn ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // Specific ingredients on top of the broad tags: allergies,
                    // intolerances, additives, anything they'd rather not eat.
                    NavigationLink {
                        DietaryRestrictionsView()
                    } label: {
                        HStack {
                            Label("Can't & won't eat", systemImage: "exclamationmark.shield")
                            Spacer()
                            Text(restrictionSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Dietary")
                } footer: {
                    Text("Frydge flags anything matching these when you scan a product or add it to your fridge or shopping list.")
                }

                // MARK: Your Data
                Section {
                    NavigationLink {
                        YourDataView(vm: vm)
                    } label: {
                        Label("Your Data", systemImage: "chart.bar.doc.horizontal")
                    }
                } footer: {
                    Text("Everything stored in Frydge — your fridge, leftovers, shopping, and shared lists and frydges.")
                }

                // MARK: Marketplace (hidden until the launch gate opens)
                if marketplace.isEnabled {
                    Section {
                        NavigationLink {
                            MarketplaceSettingsView()
                        } label: {
                            Label("Marketplace Settings", systemImage: "storefront")
                        }
                    } footer: {
                        Text("Manage your payment account and active product listings.")
                    }
                }

                // MARK: Spending
                Section {
                    Button {
                        showSpending = true
                    } label: {
                        HStack {
                            Label("Spending & Receipts", systemImage: "chart.line.uptrend.xyaxis")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Spending")
                } footer: {
                    Text("Track what you spend from scanned receipts.")
                }

                // MARK: Grocery budget
                Section {
                    NavigationLink {
                        BudgetSettingsView()
                    } label: {
                        HStack {
                            Label("Grocery Budget", systemImage: "target")
                            Spacer()
                            if budgetAmount > 0 {
                                Text("\(GroceryBudget.money(budgetAmount))/\((BudgetPeriod(rawValue: budgetPeriodRaw) ?? .weekly).shortLabel)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Set a weekly, fortnightly or monthly grocery budget. The shopping list shows how this shop and your scanned receipts stack up against it.")
                }

                // MARK: Store arrival reminders (opt-in for Always location)
                Section {
                    Toggle(isOn: $storeArrivalRemindersEnabled) {
                        Label("Store arrival reminders", systemImage: "location.fill")
                    }
                    .onChange(of: storeArrivalRemindersEnabled) { _, _ in
                        NotificationCenter.default.post(name: StoreArrivalReminders.didChange, object: nil)
                    }

                    // Manual "I'm shopping at…" override. Works without any
                    // location permission and corrects a wrong geofence.
                    Picker(selection: manualStoreSelection) {
                        Text("Automatic (location)").tag("")
                        ForEach(StoreChain.pickable) { chain in
                            Text(chain.name).tag(chain.key)
                        }
                    } label: {
                        Label("Shopping at", systemImage: "cart")
                    }

                    if let store = inStoreSession.current {
                        HStack {
                            Label {
                                Text("Currently at \(store.displayName)")
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "storefront")
                            }
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Not shopping") {
                                inStoreSession.end()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Get a nudge with your shopping list when you arrive at a supermarket. This needs “Always” location access so Frydge can notice you've arrived while it's closed. Off by default.\n\nWhile you're at a store, items that chain doesn't sell are greyed out on your shopping list and Live Activity. Pick a store here to do that by hand.")
                }
                .onAppear { inStoreSession.refreshExpiry() }

                // MARK: Apple Intelligence (on-device AI features)
                if FrydgeIntelligence.isSupportedOnDevice {
                    Section {
                        Toggle(isOn: $appleIntelligenceEnabled) {
                            Label("Apple Intelligence", systemImage: "sparkles")
                        }
                    } footer: {
                        Text("Uses your iPhone's on-device model for things like recipe import, ingredient swaps, and use-it-up ideas. Nothing leaves your device. On by default.")
                    }
                }

                // MARK: Storage & Data
                Section {
                    NavigationLink {
                        StorageDataView()
                    } label: {
                        Label("Storage & Data", systemImage: "internaldrive")
                    }
                } footer: {
                    Text("Manage cached photos, browse the recipe photo library, restore bundled recipes, or export a snapshot of your fridge and shopping list.")
                }

                // MARK: About & Legal
                Section {
                    Button {
                        showTutorial = true
                    } label: {
                        HStack {
                            Label("Show Tutorial", systemImage: "questionmark.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showLegal = true
                    } label: {
                        HStack {
                            Label("Legal & Attributions", systemImage: "doc.text")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("About")
                } footer: {
                    Text("Data sources, image credits, disclaimers, and affiliate disclosure.")
                }

                // MARK: Session
                Section {
                    Button {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Returns to the welcome screen so you can sign in with Apple again. Your recipes and fridge stay safe in iCloud.")
                }

                // MARK: Danger Zone
                Section {
                    Button(role: .destructive) {
                        showDeleteAccountConfirm = true
                    } label: {
                        Label("Delete My Data", systemImage: "trash")
                    }
                    if let msg = deleteResultMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Danger Zone")
                }
            }
            .navigationTitle("Profile")
            .task {
                await vm.refreshAll()
                seedProfileNameIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await vm.refreshAll()
                    seedProfileNameIfNeeded()
                }
            }
            .sheet(isPresented: $showSpending) {
                NavigationStack { SpendOverviewView() }
            }
            .sheet(isPresented: $showLegal) {
                LegalInfoView()
            }
            .fullScreenCover(isPresented: $showTutorial) {
                TutorialView {
                    showTutorial = false
                }
            }
            .onChange(of: avatarPickerItem) { _, item in
                guard let item else { return }
                Task { await loadAvatar(from: item) }
            }
            .confirmationDialog("Log out of Frydge?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) { logOut() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You'll return to the welcome screen and can sign in with Apple again. Your recipes and fridge stay in iCloud.")
            }
            .confirmationDialog("Delete all your data?", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    Task {
                        let result = await vm.deleteAccount()
                        deleteResultMessage = result
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes your fridge items, shopping list, meal plan, receipts and recipes from this device and iCloud, and leaves all shared lists and frydges. Marketplace order records are kept for payment reconciliation. This cannot be undone.")
            }
        }
    }

    /// Resets the first-run Sign in with Apple gate and clears the cached Apple
    /// identity so a user who is stuck can return to the welcome screen and start
    /// again. Their recipes/fridge live in iCloud and are untouched.
    private func logOut() {
        let defaults = UserDefaults.standard
        AppleSignInGate.reset()
        defaults.set(false, forKey: "hasCompletedProfileSetup")
        defaults.removeObject(forKey: "appleGivenName")
        defaults.removeObject(forKey: "appleFamilyName")
        defaults.removeObject(forKey: "appleEmail")
        FrydgeAPIService.shared.logout()
        dismiss()
        NotificationCenter.default.post(name: .frydgeDidLogout, object: nil)
    }

    private func seedProfileNameIfNeeded() {
        guard profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fallback = vm.profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback != "iCloud Account" else { return }
        profileName = fallback
        RecipeAuthor.setName(fallback)
    }

    // MARK: - Profile helpers

    private var avatarView: some View {
        ZStack {
            if let image = UIImage.frydgeBounded(data: avatarData, maxPixelSize: ImageBudget.thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 64, height: 64)
                Text(currentInitials)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.blue)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
                .background(Circle().fill(Color(.systemBackground)))
        }
        .accessibilityLabel("Change profile picture")
    }

    /// Loads the chosen photo, crops it to a small square thumbnail, and stores it
    /// so the avatar stays tiny in UserDefaults.
    private func loadAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail) else { return }
        let thumbnail = image.frydgeAvatarThumbnail(maxDimension: 256)
        if let jpeg = thumbnail.jpegData(compressionQuality: 0.8) {
            await MainActor.run { avatarData = jpeg }
        }
    }

    private var currentInitials: String {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = name.isEmpty ? vm.profileDisplayName : name
        let words = source.split(separator: " ").prefix(2).compactMap { $0.first }
        let initials = words.map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "🙂" : initials
    }

    private var selectedDietary: Set<String> {
        Set(profileDietaryCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// "3 can't · 2 avoid" or "None yet" for the Dietary row.
    private var restrictionSummary: String {
        let cannot = dietaryRestrictions.cannotEat.count
        let avoid = dietaryRestrictions.prefersToAvoid.count
        if cannot == 0 && avoid == 0 { return "None yet" }
        var parts: [String] = []
        if cannot > 0 { parts.append("\(cannot) can't") }
        if avoid > 0 { parts.append("\(avoid) avoid") }
        return parts.joined(separator: " · ")
    }

    private func toggleDietary(_ tag: String) {
        var set = selectedDietary
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        profileDietaryCSV = set.sorted().joined(separator: ",")
    }
}

// MARK: - Your Data

/// Full breakdown of everything the account owns or belongs to: item counts up
/// top, then the actual shared/owned shopping lists and frydges with swipe
/// actions to leave or delete.
private struct YourDataView: View {
    @ObservedObject var vm: ProfileViewModel
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager

    // Export / import of the one-file JSON backup (UserDataBackup.swift).
    @State private var showExporter = false
    @State private var exportDocument = FrydgeBackupDocument()
    @State private var showImporter = false
    @State private var importAlertTitle: String?
    @State private var importAlertMessage = ""
    @State private var exportedConfirmation = false

    var body: some View {
        List {
            Section {
                statRow("Fridge items", value: fridgeItemCount, systemImage: "refrigerator")
                statRow("Leftovers", value: leftoverCount, systemImage: "takeoutbag.and.cup.and.straw")
                statRow("Shopping items", value: shoppingItemCount, systemImage: "cart")
                statRow("Owned frydges", value: vm.ownedFrydges.count, systemImage: "person.2")
                statRow("Shared with me", value: vm.frydges.count + vm.shoppingLists.count, systemImage: "square.and.arrow.down")
            } header: {
                Text("Overview")
            }

            // MARK: Export / Import
            Section {
                Button {
                    exportBackup()
                } label: {
                    HStack {
                        Label("Export Your Data", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exportedConfirmation {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Label("Import Your Data", systemImage: "square.and.arrow.down")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Backup")
            } footer: {
                Text("Export saves your fridge, leftovers, shopping list, dietary rules and favourites as one file you can keep in Files or AirDrop to another device. Import merges a file back in — nothing already here is removed.")
            }

            // MARK: Shopping Lists
            if !vm.shoppingLists.isEmpty || !vm.ownedShoppingLists.isEmpty {
                Section {
                    ForEach(vm.ownedShoppingLists) { list in
                        HStack {
                            Text(list.emoji.isEmpty ? "🛒" : list.emoji)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name).fontWeight(.medium)
                                Text("\(list.itemCount) item\(list.itemCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Owner").font(.caption).foregroundStyle(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await vm.deleteOwnedList(list) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    ForEach(vm.shoppingLists) { item in
                        HStack {
                            Text(item.emoji.isEmpty ? "🛒" : item.emoji)
                            Text(item.title).fontWeight(.medium)
                            Spacer()
                            Text("Shared").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await vm.leaveShare(item) }
                            } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    }
                } header: {
                    Text("Shopping Lists")
                }
            }

            // MARK: Shared Frydges
            if !vm.frydges.isEmpty || !vm.ownedFrydges.isEmpty {
                Section {
                    ForEach(vm.ownedFrydges) { frydge in
                        HStack {
                            Text(frydge.emoji.isEmpty ? "🧊" : frydge.emoji)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(frydge.name).fontWeight(.medium)
                                Text("\(frydge.itemCount) item\(frydge.itemCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Owner").font(.caption).foregroundStyle(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await vm.deleteOwnedFrydge(frydge) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    ForEach(vm.frydges) { item in
                        HStack {
                            Text(item.emoji.isEmpty ? "🧊" : item.emoji)
                            Text(item.title).fontWeight(.medium)
                            Spacer()
                            Text("Shared").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await vm.leaveShare(item) }
                            } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    }
                } header: {
                    Text("Shared Frydges")
                }
            }
        }
        .navigationTitle("Your Data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.refreshAll() }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: UserDataBackup.defaultFilename()
        ) { result in
            if case .success = result {
                exportedConfirmation = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    exportedConfirmation = false
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importBackup(from: url)
            case .failure(let error):
                importAlertTitle = "Couldn't open file"
                importAlertMessage = error.localizedDescription
            }
        }
        .alert(
            importAlertTitle ?? "",
            isPresented: Binding(
                get: { importAlertTitle != nil },
                set: { if !$0 { importAlertTitle = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importAlertTitle = nil }
        } message: {
            Text(importAlertMessage)
        }
    }

    // MARK: Backup actions

    private func exportBackup() {
        let backup = UserDataBackup.make(frydge: frydgeManager, shopping: shoppingListManager)
        do {
            exportDocument = FrydgeBackupDocument(data: try UserDataBackup.encode(backup))
            showExporter = true
        } catch {
            importAlertTitle = "Couldn't export"
            importAlertMessage = error.localizedDescription
        }
    }

    private func importBackup(from url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let backup = try UserDataBackup.decode(data)
            let summary = UserDataBackup.restore(backup, into: frydgeManager, shopping: shoppingListManager)
            importAlertTitle = summary.isEmpty ? "Nothing new to import" : "Import complete"
            importAlertMessage = summary.message
            Task { await vm.refreshAll() }
        } catch {
            importAlertTitle = "That isn't a Frydge backup"
            importAlertMessage = "Choose a file exported from Profile → Your Data. (\(error.localizedDescription))"
        }
    }

    private var fridgeItemCount: Int {
        frydgeManager.storedIngredients.filter { $0.lifecycle == .fridge }.count
    }

    private var leftoverCount: Int {
        frydgeManager.leftovers.count
    }

    private var shoppingItemCount: Int {
        shoppingListManager.shoppingListItems.count
    }

    private func statRow(_ label: String, value: Int, systemImage: String) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let frydgeForceImageSync = Notification.Name("FrydgeForceImageSync")
}

// MARK: - Avatar thumbnail

extension UIImage {
    /// Center-cropped square thumbnail, downscaled so avatars stay tiny in storage.
    func frydgeAvatarThumbnail(maxDimension: CGFloat) -> UIImage {
        let target = CGSize(width: maxDimension, height: maxDimension)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            // Aspect-fill the square, cropping the overflow evenly on both axes.
            let scale = max(target.width / size.width, target.height / size.height)
            let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (target.width - scaledSize.width) / 2,
                                 y: (target.height - scaledSize.height) / 2)
            draw(in: CGRect(origin: origin, size: scaledSize))
        }
    }
}

// MARK: - Marketplace Settings

private struct MarketplaceSettingsView: View {
    @State private var showStripeSetup = false
    @State private var showMarketplace = false

    var body: some View {
        List {
            Section {
                Button {
                    showStripeSetup = true
                } label: {
                    HStack {
                        Label("Payments & Payouts", systemImage: "creditcard.fill")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    showMarketplace = true
                } label: {
                    HStack {
                        Label("My Listings", systemImage: "storefront")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("Manage your payment account and active product listings.")
            }
        }
        .navigationTitle("Marketplace")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showStripeSetup) {
            PaymentsView()
        }
        .sheet(isPresented: $showMarketplace) {
            LocalMarketplaceView(startWithMyListings: true)
        }
    }
}

// MARK: - Storage & Data

/// Single home for on-device storage (the image cache) and data/files actions
/// (photo library, recipe reset, and exporting a snapshot of current items).
private struct StorageDataView: View {
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager

    @State private var cacheSize = "Calculating…"
    @State private var isSyncingImages = false
    @State private var imageSyncDone = false
    @State private var isClearingCache = false

    @State private var showPhotoLibrary = false
    @State private var showResetRecipesConfirm = false
    @State private var recipeResetDone = false
    @State private var currentItemsText = ""
    @State private var showCurrentItemsExporter = false

    var body: some View {
        List {
            // MARK: Image cache (storage)
            Section {
                HStack {
                    Label("Image Cache", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    Text(cacheSize)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button {
                    guard !isSyncingImages else { return }
                    isSyncingImages = true
                    imageSyncDone = false
                    Task {
                        ProductImageCacheManager.shared.clearAll()
                        cacheSize = "0 KB"
                        NotificationCenter.default.post(name: .frydgeForceImageSync, object: nil)
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        isSyncingImages = false
                        imageSyncDone = true
                        cacheSize = ProductImageCacheManager.shared.diskUsageFormatted()
                    }
                } label: {
                    HStack {
                        if isSyncingImages {
                            ProgressView().scaleEffect(0.85)
                            Text("Re-downloading images…")
                        } else if imageSyncDone {
                            Label("Images refreshed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Refresh Product Images", systemImage: "arrow.clockwise.icloud")
                        }
                        Spacer()
                    }
                }
                .disabled(isSyncingImages)
                .foregroundStyle(.primary)

                Button(role: .destructive) {
                    guard !isClearingCache else { return }
                    isClearingCache = true
                    ProductImageCacheManager.shared.clearAll()
                    cacheSize = "0 KB"
                    isClearingCache = false
                } label: {
                    HStack {
                        Label("Clear Image Cache", systemImage: "trash")
                        Spacer()
                    }
                }
                .disabled(isClearingCache)
            } header: {
                Text("Storage")
            } footer: {
                Text("Refresh re-downloads all photos. Clear removes them without re-downloading.")
            }

            // MARK: Data & files
            Section {
                Button {
                    showPhotoLibrary = true
                } label: {
                    HStack {
                        Label("Recipe Photo Library", systemImage: "photo.stack")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                Button(role: .destructive) {
                    showResetRecipesConfirm = true
                } label: {
                    if recipeResetDone {
                        Label("Recipes reset to defaults", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Reset Recipes to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }

                Button {
                    currentItemsText = buildCurrentItemsText()
                    showCurrentItemsExporter = true
                } label: {
                    HStack {
                        Label("Save Current Items", systemImage: "square.and.arrow.down")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Data & Files")
            } footer: {
                Text("Browse all cached food photos, restore bundled recipes, or export a snapshot of your fridge and shopping list to Files.")
            }
        }
        .navigationTitle("Storage & Data")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheSize = ProductImageCacheManager.shared.diskUsageFormatted() }
        .sheet(isPresented: $showPhotoLibrary) {
            RecipePhotoLibraryView()
        }
        .fileExporter(
            isPresented: $showCurrentItemsExporter,
            document: CurrentItemsTextDocument(text: currentItemsText),
            contentType: .plainText,
            defaultFilename: "Frydge-Items-\(currentDateString())"
        ) { _ in }
        .confirmationDialog(
            "Reset recipes to the 200 bundled defaults?",
            isPresented: $showResetRecipesConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                NotificationCenter.default.post(name: .frydgeResetRecipesToDefaults, object: nil)
                recipeResetDone = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    recipeResetDone = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your cloud-synced recipes will be removed from the local cache. They can be re-fetched from iCloud at any time.")
        }
    }

    private func currentDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func buildCurrentItemsText() -> String {
        var lines: [String] = []
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
        lines.append("Frydge — Working Files")
        lines.append("Exported: \(dateStr)")
        lines.append("")

        let fridgeItems = frydgeManager.storedIngredients
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("FRIDGE  (\(fridgeItems.count) item\(fridgeItems.count == 1 ? "" : "s"))")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if fridgeItems.isEmpty {
            lines.append("  (empty)")
        } else {
            for item in fridgeItems.sorted(by: { $0.name < $1.name }) {
                let qty = item.quantity.trimmingCharacters(in: .whitespaces)
                let unit = item.unit.trimmingCharacters(in: .whitespaces)
                let amount = [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append("  • \(item.name)\(amount.isEmpty ? "" : "  ×  \(amount)")")
            }
        }
        lines.append("")

        let shopItems = shoppingListManager.shoppingListItems
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("SHOPPING LIST  (\(shopItems.count) item\(shopItems.count == 1 ? "" : "s"))")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if shopItems.isEmpty {
            lines.append("  (empty)")
        } else {
            for item in shopItems.sorted(by: { $0.name < $1.name }) {
                let qty = item.quantity.trimmingCharacters(in: .whitespaces)
                let unit = item.unit.trimmingCharacters(in: .whitespaces)
                let amount = [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append("  • \(item.name)\(amount.isEmpty ? "" : "  ×  \(amount)")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Recipe Photo Library

private struct RecipePhotoLibraryView: View {
    @State private var entries: [CachedProductImageInfo] = []
    @State private var searchText = ""

    private var filtered: [CachedProductImageInfo] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.productName.localizedCaseInsensitiveContains(searchText) }
    }

    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Photos Yet",
                        systemImage: "photo.stack",
                        description: Text("Food photos appear here as you browse ingredients and recipes.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filtered, id: \.itemKey) { entry in
                                CachedImageCell(entry: entry)
                            }
                        }
                        .padding()
                    }
                    .searchable(text: $searchText, prompt: "Search photos")
                }
            }
            .navigationTitle("Photo Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !entries.isEmpty {
                        Text("\(filtered.count) photo\(filtered.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            entries = await Task.detached(priority: .background) {
                ProductImageCacheManager.shared.allCachedEntries()
            }.value
        }
    }
}

private struct CachedImageCell: View {
    let entry: CachedProductImageInfo
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.1)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary.opacity(0.4))
                        )
                }
            }
            .frame(height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Text(entry.productName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            let key = entry.itemKey
            image = await Task.detached(priority: .background) {
                ProductImageCacheManager.shared.uiImage(forKey: key)
            }.value
        }
    }
}

// MARK: - Payments & Payouts

/// Clean, minimal payments screen: the get-paid (Stripe Connect) flow up front,
/// a reassurance that buying works out of the box, and developer/config options
/// tucked away behind a disclosure.
private struct PaymentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Receive payments (Stripe Connect Express hosted onboarding)
                    StripeConnectView()

                    // Buyers need no setup.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Buying is ready").font(.headline)
                        }
                        Text("Pay sellers with Apple Pay or card at checkout — nothing to set up.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    Text("Payments are processed securely by Stripe. Bank details and identity checks are handled on Stripe's hosted pages — Frydge never sees or stores them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    NavigationLink {
                        QuickStripeSetup()
                    } label: {
                        Label("Advanced payment settings", systemImage: "gearshape")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Payments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Legal & Attributions

private struct LegalInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    legalBlock(
                        "Recipes",
                        "Bundled recipes are original method text written for Frydge for common, widely-known dishes. Recipes (lists of ingredients and steps) are provided for general information only. Always check ingredients and packaging for your own dietary and allergen needs."
                    )
                }

                Section {
                    legalBlock(
                        "Recipe Images",
                        "Recipe photos in the bundled pack are sourced from Wikimedia Commons and used under their respective licences. Each recipe carries its individual image credit, author and licence."
                    )
                }

                Section {
                    legalBlock(
                        "Product & Nutrition Data",
                        "Product names, images and nutrition information are provided by Open Food Facts and its contributors, made available under the Open Database License (ODbL); product images under Creative Commons licences. Data is community-maintained and may be incomplete or inaccurate."
                    )
                    Link("openfoodfacts.org", destination: URL(string: "https://world.openfoodfacts.org")!)
                        .font(.footnote)
                }

                Section {
                    legalBlock(
                        "Nutrition & Allergen Disclaimer",
                        "Nutrition figures are indicative, typically per 100 g/ml, and are not a substitute for professional medical or dietary advice. Do not rely on this app for allergen safety — always confirm with the product packaging."
                    )
                }

                Section {
                    legalBlock(
                        "Prices & Availability",
                        "Store prices, stock and locations are estimates gathered from third-party sources and may be out of date. Confirm the current price in-store or on the retailer's website before purchasing."
                    )
                }

                Section {
                    legalBlock(
                        "Affiliate & Partner Links",
                        "Frydge may include affiliate or partner links to retailers. If you buy through one of these links, we may earn a small commission at no extra cost to you. Where a link is an affiliate link, it will be marked as such where it appears."
                    )
                }

                Section {
                    legalBlock(
                        "Payments",
                        "Marketplace payments are processed by Stripe. Frydge does not store your full card details. Your use of payments is also subject to Stripe's terms and privacy policy."
                    )
                    Link("stripe.com/privacy", destination: URL(string: "https://stripe.com/privacy")!)
                        .font(.footnote)
                }

                // Frydge's own policies. App Review looks for these, and the
                // privacy URL must match the one in App Store Connect.
                Section {
                    if let url = URL(string: LegalLinks.privacyPolicy) {
                        Link(destination: url) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                    }
                    if let url = URL(string: LegalLinks.termsOfUse) {
                        Link(destination: url) {
                            Label("Terms of Use", systemImage: "doc.text")
                        }
                    }
                    if let url = URL(string: LegalLinks.support) {
                        Link(destination: url) {
                            Label("Contact Support", systemImage: "envelope")
                        }
                    }
                } header: {
                    Text("Frydge")
                } footer: {
                    Text("Version \(Bundle.main.appVersionDisplay)")
                }
            }
            .navigationTitle("Legal & Attributions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func legalBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Frydge's own policy links

/// One place to change these. The privacy URL must match the one entered in
/// App Store Connect, or review will flag the mismatch.
enum LegalLinks {
    static let privacyPolicy = "https://frydge2.com/privacy"
    static let termsOfUse    = "https://frydge2.com/terms"
    static let support       = "https://frydge2.com/support"
}

extension Bundle {
    /// "1.0 (162)" for the About footer.
    var appVersionDisplay: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - Current Items Export Document

private struct CurrentItemsTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - ViewModel

@MainActor
final class ProfileViewModel: ObservableObject {
    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

    @Published var isLoading: Bool = false
    @Published var accountStatusText: String = "Checking iCloud…"
    @Published var accountDetailText: String? = "Checking the iCloud account on this device."
    @Published var isICloudAvailable: Bool = false
    @Published var appleDisplayName: String? = nil
    @Published var appleEmail: String? = nil
    @Published var identitySourceText: String? = nil
    @Published var userRecordName: String? = nil
    @Published var shoppingLists: [SharedMembership] = []
    @Published var ownedShoppingLists: [OwnedShoppingList] = []  // ✅ Owned shopping lists
    @Published var frydges: [SharedMembership] = []
    @Published var ownedFrydges: [OwnedFrydge] = []  // ✅ Owned frydges
    @Published var otherSharedAreas: [SharedMembership] = []
    @Published var lastError: String? = nil

    var profileDisplayName: String {
        if let appleDisplayName, !appleDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appleDisplayName
        }

        if let appleEmail, let prefix = appleEmail.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }

        let authorName = RecipeAuthor.currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authorName.isEmpty && authorName != UIDevice.current.name {
            return authorName
        }

        return "iCloud Account"
    }

    var profileInitials: String {
        let words = profileDisplayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }

        return words.map { String($0).uppercased() }.joined()
    }

    // Heuristics: update to match your actual root record types/titles.
    private let shoppingRootTypeHints: [String] = ["shopping", "list"]
    private let frydgeRootTypeHints: [String] = ["frydge", "fridge"]

    // Record types to purge on delete-account (user-contributed items).
    private let sharedUserRecordTypesToPurge: [String] = [
        "ShoppingListItem",
        "FridgeItem"
    ]

    private static func isMissingZoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .zoneNotFound || ckError.code == .unknownItem
    }

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }

        lastError = nil
        loadStoredAppleIdentity()
        let isAvailable = await fetchAccountIdentity()

        guard isAvailable else {
            shoppingLists = []
            ownedShoppingLists = []
            frydges = []
            ownedFrydges = []
            otherSharedAreas = []
            return
        }

        // ✅ Fetch owned and shared for both shopping lists and frydges
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchSharedMemberships() }
            group.addTask { await self.fetchOwnedShoppingLists() }
            group.addTask { await self.fetchOwnedFrydges() }
        }
    }

    // MARK: Identity

    private func fetchAccountIdentity() async -> Bool {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                isICloudAvailable = true
                accountStatusText = "iCloud available"
                accountDetailText = "Recipes, shared frydges, and shopping lists can sync with iCloud."
                identitySourceText = "Using your active iCloud account and any Apple identity details you previously chose to share with the app."
            case .noAccount:
                clearUnavailableAccountState(
                    status: "No iCloud account on this device",
                    detail: "Sign in to iCloud in Settings to sync Frydge data."
                )
                return false
            case .restricted:
                clearUnavailableAccountState(
                    status: "iCloud restricted",
                    detail: "This device is not currently allowed to use iCloud."
                )
                return false
            case .couldNotDetermine:
                clearUnavailableAccountState(
                    status: "iCloud status could not be determined",
                    detail: "Frydge could not confirm the iCloud account right now."
                )
                return false
            case .temporarilyUnavailable:
                clearUnavailableAccountState(
                    status: "iCloud temporarily unavailable",
                    detail: "iCloud is temporarily unavailable. Pull to refresh in a moment."
                )
                return false
            @unknown default:
                clearUnavailableAccountState(
                    status: "Unknown iCloud status",
                    detail: "Frydge received an iCloud account status it does not recognise yet."
                )
                return false
            }

            let rid = try await container.userRecordID()
            userRecordName = rid.recordName
            await enrichIdentityFromUserRecord(recordID: rid)
            return true
        } catch {
            clearUnavailableAccountState(
                status: "iCloud error",
                detail: "Frydge could not reach iCloud: \(error.localizedDescription)"
            )
            lastError = "iCloud error: \(error.localizedDescription)"
            return false
        }
    }

    private func clearUnavailableAccountState(status: String, detail: String) {
        isICloudAvailable = false
        accountStatusText = status
        accountDetailText = detail
        userRecordName = nil
        identitySourceText = nil
    }

    private func loadStoredAppleIdentity() {
        let defaults = UserDefaults.standard

        let fullName = [
            defaults.string(forKey: "appleGivenName")?.trimmingCharacters(in: .whitespacesAndNewlines),
            defaults.string(forKey: "appleFamilyName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " ")

        appleDisplayName = fullName.isEmpty ? appleDisplayName : fullName
        if let appleDisplayName, !appleDisplayName.isEmpty {
            RecipeAuthor.setName(appleDisplayName)
        }

        let email = defaults.string(forKey: "appleEmail")?.trimmingCharacters(in: .whitespacesAndNewlines)
        appleEmail = (email?.isEmpty == false) ? email : appleEmail
    }

    private func enrichIdentityFromUserRecord(recordID: CKRecord.ID) async {
        do {
            let privateDB = container.privateCloudDatabase
            let userRecord = try await privateDB.record(for: recordID)

            if appleDisplayName == nil || appleDisplayName?.isEmpty == true {
                let discoveredName = [
                    (userRecord["firstName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    (userRecord["lastName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " ")

                if !discoveredName.isEmpty {
                    appleDisplayName = discoveredName
                    RecipeAuthor.setName(discoveredName)
                }
            }

            if appleEmail == nil || appleEmail?.isEmpty == true {
                let discoveredEmail = (userRecord["email"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let discoveredEmail, !discoveredEmail.isEmpty {
                    appleEmail = discoveredEmail
                }
            }
        } catch {
            // Best-effort only. Some accounts will not expose these fields.
        }
    }

    // MARK: Memberships (per-zone queries for shared database)

    private func fetchSharedMemberships() async {
        let sharedDB = container.sharedCloudDatabase

        do {
            // Shared DB requires querying PER ZONE (zone-wide queries are not supported).
            let zones = try await sharedDB.fetchAllRecordZonesAsync()

            var memberships: [SharedMembership] = []
            memberships.reserveCapacity(zones.count)
            var seenMembershipKeys: Set<String> = []

            // For each shared zone, fetch the root record directly
            for zone in zones {
                let zoneID = zone.zoneID
                
                // Skip the default zone - we only care about custom zones
                if zoneID.zoneName == CKRecordZone.ID.defaultZoneName {
                    continue
                }
                
                do {
                    // Try to find the root record by fetching all records in the zone
                    // We'll look for ShareAnchor records which are typically the root
                    let records = try await sharedDB.queryRecordsAsync(
                        recordType: "ShareAnchor",
                        predicate: NSPredicate(value: true),
                        zoneID: zoneID,
                        desiredKeys: ["name", "title", "emoji", "category"]
                    )
                    
                    // Process each root record found
                    for rootRecord in records {
                        let rootID = rootRecord.recordID
                        
                        let titleFromRoot =
                            (rootRecord["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
                            (rootRecord["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
                            ""

                        let title = !titleFromRoot.isEmpty ? titleFromRoot : rootID.recordName

                        let emoji =
                            (rootRecord["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        let category = classifyFromRoot(rootRecord: rootRecord)

                        let membershipKey = "\(rootID.zoneID.ownerName)|\(rootID.zoneID.zoneName)|\(rootID.recordName)"
                        guard !seenMembershipKeys.contains(membershipKey) else { continue }
                        seenMembershipKeys.insert(membershipKey)

                        // We don't have the share record ID directly, so use the root record ID as a placeholder
                        memberships.append(
                            SharedMembership(
                                id: membershipKey,
                                title: title,
                                emoji: emoji,
                                shareRecordID: rootID, // Using root as placeholder
                                rootRecordID: rootID,
                                category: category
                            )
                        )
                    }
                } catch {
                    // Skip zones that fail to query (may not have permission or other issues)
                    print("[ProfileViewModel] ⚠️ Failed to query zone \(zoneID.zoneName): \(error.localizedDescription)")
                    continue
                }
            }

            let shopping = memberships
                .filter { $0.category == .shoppingList }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }

            let fr = memberships
                .filter { $0.category == .frydge }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }

            let unknown = memberships
                .filter { $0.category == .unknown }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }

            shoppingLists = shopping
            frydges = fr
            otherSharedAreas = unknown
            if shopping.isEmpty && fr.isEmpty && unknown.isEmpty {
                if identitySourceText == nil || identitySourceText?.isEmpty == true {
                    identitySourceText = "Using your active iCloud account. No shared lists or frydges were found for this account."
                }
            } else {
                identitySourceText = "Using your active iCloud account. Shared areas below reflect the lists and frydges this account currently belongs to."
            }
        } catch {
            lastError = "Failed to load shared memberships: \(error.localizedDescription)"
            print("[ProfileViewModel] ❌ Error fetching shared memberships: \(error)")
            shoppingLists = []
            frydges = []
            otherSharedAreas = []
            identitySourceText = "Using your active iCloud account, but shared memberships could not be loaded right now."
        }
    }

    private func classifyFromRoot(rootRecord: CKRecord) -> SharedMembership.Category {
        let rootRecordType = rootRecord.recordType
        let title = ((rootRecord["name"] as? String) ?? (rootRecord["title"] as? String) ?? "")
        let category = ((rootRecord["category"] as? String) ?? "")
        let zoneName = rootRecord.recordID.zoneID.zoneName

        let hay = [rootRecordType, title, category, zoneName]
            .joined(separator: " ")
            .lowercased()

        if hay.contains("shoppinglist") || hay.contains("shopping list") || hay.contains("shoppinglistroot") || hay.contains("shoppinglistzone") || shoppingRootTypeHints.contains(where: { hay.contains($0) }) {
            return .shoppingList
        }
        if hay.contains("frydge") || hay.contains("fridge") || hay.contains("fridgeroot") || frydgeRootTypeHints.contains(where: { hay.contains($0) }) {
            return .frydge
        }
        return .unknown
    }

    // MARK: Leave share (swipe-to-delete)

    func leaveShare(_ item: SharedMembership) async {
        let sharedDB = container.sharedCloudDatabase

        do {
            // Delete just this share: the zone can hold other shares from the same
            // owner, and deleting it would silently drop the user from all of them.
            do {
                _ = try await sharedDB.deleteRecord(withID: item.shareRecordID)
            } catch {
                _ = try await sharedDB.deleteRecordZone(withID: item.rootRecordID.zoneID)
            }
            await refreshAll()
        } catch {
            lastError = "Failed to leave \(item.title): \(error.localizedDescription)"
        }
    }
    
    // MARK: - ✅ NEW: Owned Shopping Lists Management
    
    /// Fetches shopping lists owned by the current user from private DB
    private func fetchOwnedShoppingLists() async {
        let privateDB = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "ShoppingListZone", ownerName: CKCurrentUserDefaultName)
        
        do {
            let pred = NSPredicate(format: "category == %@", "ShoppingListRoot")
            let query = CKQuery(recordType: "ShareAnchor", predicate: pred)
            
            let (matches, _) = try await privateDB.records(matching: query, inZoneWith: zoneID)
            
            var owned: [OwnedShoppingList] = []
            for (_, result) in matches {
                guard case .success(let record) = result else { continue }
                
                let name = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unnamed"
                let emoji = (record["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "🛒"
                
                // Count items
                var itemCount = 0
                if let itemsJSON = record["itemsJSON"] as? String,
                   let data = itemsJSON.data(using: .utf8),
                   let items = try? JSONDecoder().decode([AnyCodable].self, from: data) {
                    itemCount = items.count
                } else if let items = record["items"] as? [String] {
                    itemCount = items.count
                }
                
                owned.append(OwnedShoppingList(
                    id: record.recordID.recordName,
                    recordID: record.recordID,
                    name: name,
                    emoji: emoji,
                    itemCount: itemCount
                ))
            }
            
            ownedShoppingLists = owned.sorted { $0.name.lowercased() < $1.name.lowercased() }
            print("[ProfileViewModel] ✅ Fetched \(owned.count) owned shopping lists")
        } catch {
            ownedShoppingLists = []
            // A user who has never created a shared list simply has no zone yet —
            // that's an empty state, not an error worth surfacing.
            if Self.isMissingZoneError(error) {
                print("[ProfileViewModel] ℹ️ No owned shopping-list zone yet")
            } else {
                print("[ProfileViewModel] ❌ Failed to fetch owned lists: \(error)")
                lastError = "Couldn't load your owned shopping lists. Pull to refresh to try again."
            }
        }
    }
    
    /// Deletes an owned shopping list permanently
    func deleteOwnedList(_ list: OwnedShoppingList) async {
        let privateDB = container.privateCloudDatabase
        
        do {
            // Fetch the record first to get the share reference if it exists
            let record = try await privateDB.record(for: list.recordID)
            
            // Delete the share if it exists
            if let shareRef = record.share {
                _ = try? await privateDB.deleteRecord(withID: shareRef.recordID)
            }
            
            // Delete the anchor record
            _ = try await privateDB.deleteRecord(withID: list.recordID)
            
            print("[ProfileViewModel] ✅ Deleted list: \(list.name)")
            await refreshAll()
        } catch {
            print("[ProfileViewModel] ❌ Failed to delete \(list.name): \(error)")
            lastError = "Failed to delete \(list.name): \(error.localizedDescription)"
        }
    }
    
    // MARK: - ✅ Owned Frydges Management
    
    /// Fetches frydges owned by the current user from private DB
    private func fetchOwnedFrydges() async {
        let privateDB = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "FrydgeFridgeZone", ownerName: CKCurrentUserDefaultName)
        
        do {
            // Must match the category SharedFridgeManager writes ("Fridge"); the old
            // "FridgeRoot" value matched nothing, so owned frydges never appeared here.
            let pred = NSPredicate(format: "category == %@", "Fridge")
            let query = CKQuery(recordType: "ShareAnchor", predicate: pred)
            
            let (matches, _) = try await privateDB.records(matching: query, inZoneWith: zoneID)
            
            var owned: [OwnedFrydge] = []
            for (_, result) in matches {
                guard case .success(let record) = result else { continue }
                
                let name = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unnamed"
                let emoji = (record["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "🧊"
                
                // Count items
                var itemCount = 0
                if let itemsJSON = record["itemsJSON"] as? String,
                   let data = itemsJSON.data(using: .utf8),
                   let items = try? JSONDecoder().decode([AnyCodable].self, from: data) {
                    itemCount = items.count
                } else if let items = record["items"] as? [String] {
                    itemCount = items.count
                }
                
                owned.append(OwnedFrydge(
                    id: record.recordID.recordName,
                    recordID: record.recordID,
                    name: name,
                    emoji: emoji,
                    itemCount: itemCount
                ))
            }
            
            ownedFrydges = owned.sorted { $0.name.lowercased() < $1.name.lowercased() }
            print("[ProfileViewModel] ✅ Fetched \(owned.count) owned frydges")
        } catch {
            print("[ProfileViewModel] ❌ Failed to fetch owned frydges: \(error)")
            ownedFrydges = []
            lastError = "Failed to load owned frydges: \(error.localizedDescription)"
        }
    }
    
    /// Deletes an owned frydge permanently
    func deleteOwnedFrydge(_ frydge: OwnedFrydge) async {
        let privateDB = container.privateCloudDatabase
        
        do {
            // Fetch the record first to get the share reference if it exists
            let record = try await privateDB.record(for: frydge.recordID)
            
            // The frydge's items are separate StoredIngredient records linked by a
            // reference; remove them too so they aren't orphaned in the zone.
            let anchorRef = CKRecord.Reference(recordID: frydge.recordID, action: .none)
            let itemQuery = CKQuery(
                recordType: "StoredIngredient",
                predicate: NSPredicate(format: "fridge == %@", anchorRef)
            )
            let itemIDs = ((try? await privateDB.allRecords(matching: itemQuery, inZoneWith: frydge.recordID.zoneID)) ?? [])
                .map(\.recordID)
            for start in stride(from: 0, to: itemIDs.count, by: 300) {
                let chunk = Array(itemIDs[start..<min(start + 300, itemIDs.count)])
                _ = try? await privateDB.modifyRecords(saving: [], deleting: chunk)
            }

            // Delete the share if it exists
            if let shareRef = record.share {
                _ = try? await privateDB.deleteRecord(withID: shareRef.recordID)
            }

            // Delete the anchor record
            _ = try await privateDB.deleteRecord(withID: frydge.recordID)

            print("[ProfileViewModel] ✅ Deleted frydge: \(frydge.name)")
            await refreshAll()
        } catch {
            print("[ProfileViewModel] ❌ Failed to delete \(frydge.name): \(error)")
            lastError = "Failed to delete \(frydge.name): \(error.localizedDescription)"
        }
    }

    // MARK: Delete account (best-effort)

    /// Deletes the user's data in a fixed order and reports exactly what
    /// succeeded, what failed and what is deliberately retained. Each step is
    /// independent so a failure in one does not skip the others, and the
    /// returned text never claims a step that did not complete.
    func deleteAccount() async -> String {
        isLoading = true
        defer { isLoading = false }

        var messages: [String] = []
        var failures = 0

        // 1) Leave all shares
        let allMemberships = shoppingLists + frydges
        for m in allMemberships {
            await leaveShare(m)
        }
        messages.append("Left all shared frydges and shopping lists.")

        // 2) Delete user-created records in shared zones, page by page.
        do {
            let rid = try await container.userRecordID()
            let sharedDB = container.sharedCloudDatabase

            for type in sharedUserRecordTypesToPurge {
                let pred = NSPredicate(format: "creatorUserRecordID == %@", rid)
                let query = CKQuery(recordType: type, predicate: pred)
                do {
                    let deleted = try await deleteAllRecords(matching: query, in: sharedDB)
                    if deleted > 0 {
                        messages.append("Removed \(deleted) of your items from shared areas (\(type)).")
                    }
                } catch {
                    failures += 1
                    messages.append("Could not remove your shared \(type) records: \(error.localizedDescription)")
                }
            }
        } catch {
            failures += 1
            messages.append("Could not resolve your iCloud user ID, so shared contributions were not removed: \(error.localizedDescription)")
        }

        // 3) Delete recipes from the public database, page by page.
        do {
            let deleted = try await deleteAllRecipesFromCloud()
            messages.append(deleted > 0 ? "Deleted \(deleted) recipes from iCloud." : "No recipes to delete.")
        } catch {
            failures += 1
            messages.append("Failed to delete recipes: \(error.localizedDescription)")
        }

        // 4) Personal inventory, shopping list, meal plan and recurring items.
        //    Hard-deleting the Core Data rows exports CKRecord deletions through
        //    the CloudKit mirror, so the private-database copies go too. The
        //    managers are then reloaded so no in-memory array (and no App Group
        //    or JSON backup written from it) can reseed the emptied store.
        if let count = PersistenceController.shared.deleteAllSyncedData() {
            await MainActor.run {
                FrydgeManager.shared.reloadFromStore()
                ShoppingListManager.current?.reloadFromStore()
                WeekPlanStore.shared.reloadFromStore()
            }
            messages.append("Removed \(count) fridge, shopping list and meal plan records from this device and iCloud.")
        } else {
            failures += 1
            messages.append("Could not remove fridge, shopping list and meal plan data; it is still on this device and in iCloud.")
        }

        // 5) Receipts (private CloudKit records with their own store).
        let receiptStore = ReceiptStore.shared
        await receiptStore.load()
        let receipts = receiptStore.receipts
        for receipt in receipts {
            await receiptStore.delete(receipt)
        }
        if let error = receiptStore.lastError {
            failures += 1
            messages.append("Some receipts could not be deleted: \(error)")
        } else if !receipts.isEmpty {
            messages.append("Deleted \(receipts.count) receipts.")
        }

        // 6) Retained records, stated so the summary matches what happened.
        messages.append("Marketplace order and payment records are kept for payment reconciliation and are not deleted here.")

        if failures > 0 {
            messages.insert("Deletion is incomplete: \(failures) step\(failures == 1 ? "" : "s") failed. You can run Delete Everything again to retry.", at: 0)
        } else {
            messages.insert("Deletion complete.", at: 0)
        }

        return messages.joined(separator: "\n")
    }

    /// Deletes every record matching `query`, following the query cursor until
    /// CloudKit reports no more pages, and deleting in batches within the
    /// per-operation limit. Returns the number of records deleted. Throws on
    /// the first page or batch failure so the caller reports a partial result
    /// rather than silent success.
    private func deleteAllRecords(matching query: CKQuery, in database: CKDatabase) async throws -> Int {
        var ids: [CKRecord.ID] = []
        var (matchResults, cursor) = try await database.records(matching: query, desiredKeys: [])
        while true {
            for (recordID, result) in matchResults {
                if case .success = result { ids.append(recordID) }
            }
            guard let next = cursor else { break }
            (matchResults, cursor) = try await database.records(continuingMatchFrom: next, desiredKeys: [])
        }

        guard !ids.isEmpty else { return 0 }

        var deleted = 0
        let batchSize = 400
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            let (_, deleteResults) = try await database.modifyRecords(saving: [], deleting: batch)
            for (_, result) in deleteResults {
                if case .failure(let error) = result {
                    throw error
                }
                deleted += 1
            }
            start += batchSize
        }
        return deleted
    }

    private func deleteAllRecipesFromCloud() async throws -> Int {
        let publicDB = container.publicCloudDatabase

        // MUST be scoped to the caller. An unscoped predicate matches every
        // user's Recipe records in the public database, and CloudKit lets the
        // request attempt to delete all of them — one account deletion would
        // try to empty the whole shared catalogue.
        let userID = try await container.userRecordID()
        let predicate = NSPredicate(
            format: "creatorUserRecordID == %@",
            CKRecord.Reference(recordID: userID, action: .none)
        )
        let query = CKQuery(recordType: "Recipe", predicate: predicate)
        return try await deleteAllRecords(matching: query, in: publicDB)
    }
}

// MARK: - SharedMembership model

struct SharedMembership: Identifiable, Hashable {
    enum Category: Hashable {
        case shoppingList
        case frydge
        case unknown
    }

    let id: String
    let title: String
    let emoji: String
    let shareRecordID: CKRecord.ID
    let rootRecordID: CKRecord.ID
    let category: Category
}

// MARK: - OwnedShoppingList model

struct OwnedShoppingList: Identifiable {
    let id: String
    let recordID: CKRecord.ID
    let name: String
    let emoji: String
    let itemCount: Int
}

// MARK: - OwnedFrydge model

struct OwnedFrydge: Identifiable {
    let id: String
    let recordID: CKRecord.ID
    let name: String
    let emoji: String
    let itemCount: Int
}

// MARK: - AnyCodable helper for JSON decoding

private struct AnyCodable: Codable {
    let value: Any
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        // Not needed for our use case
    }
}

// MARK: - CKDatabase async helpers

private extension CKDatabase {
    func add(_ op: CKDatabaseOperation) async throws {
        try await withCheckedThrowingContinuation { cont in
            op.database = self
            self.add(op)

            if let modify = op as? CKModifyRecordsOperation {
                modify.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            } else {
                cont.resume()
            }
        }
    }

    func deleteRecord(withID id: CKRecord.ID) async throws -> CKRecord.ID {
        try await withCheckedThrowingContinuation { cont in
            self.delete(withRecordID: id) { deletedID, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let deletedID = deletedID {
                    cont.resume(returning: deletedID)
                } else {
                    cont.resume(
                        throwing: NSError(
                            domain: "CKDatabase.delete",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unknown delete failure"]
                        )
                    )
                }
            }
        }
    }

    func record(for id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            self.fetch(withRecordID: id) { record, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let record = record {
                    cont.resume(returning: record)
                } else {
                    cont.resume(
                        throwing: NSError(
                            domain: "CKDatabase.fetch",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Record not found"]
                        )
                    )
                }
            }
        }
    }

    // Shared DB requires zone-scoped operations; this enables that.
    func fetchAllRecordZonesAsync() async throws -> [CKRecordZone] {
        try await withCheckedThrowingContinuation { cont in
            self.fetchAllRecordZones { zones, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: zones ?? [])
                }
            }
        }
    }

    func queryRecordsAsync(
        recordType: String,
        predicate: NSPredicate,
        zoneID: CKRecordZone.ID,
        desiredKeys: [String]?
    ) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { cont in
            let query = CKQuery(recordType: recordType, predicate: predicate)
            let op = CKQueryOperation(query: query)
            op.zoneID = zoneID
            op.desiredKeys = desiredKeys

            var records: [CKRecord] = []
            records.reserveCapacity(64)

            op.recordMatchedBlock = { _, result in
                if case .success(let record) = result {
                    records.append(record)
                }
            }

            op.queryResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: records)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }

            self.add(op)
        }
    }

    func deleteRecordZone(withID id: CKRecordZone.ID) async throws -> CKRecordZone.ID {
        try await withCheckedThrowingContinuation { cont in
            self.delete(withRecordZoneID: id) { deletedID, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let deletedID = deletedID {
                    cont.resume(returning: deletedID)
                } else {
                    cont.resume(
                        throwing: NSError(
                            domain: "CKDatabase.deleteZone",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unknown zone delete failure"]
                        )
                    )
                }
            }
        }
    }
}
