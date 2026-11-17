//
//  RecipeImportWizardView.swift
//  FrydgeRecipes
//
//  Created by Josh on 01/06/2026.
//
//  4-step confirmation wizard after a recipe import draft is ready.
//  Steps: 1 Photo  →  2 Ingredients  →  3 Pans  →  4 Instructions  →  Save
//

import SwiftUI
import PhotosUI
import CloudKit

struct RecipeImportWizardView: View {
    @Environment(\.dismiss) private var dismiss

    // Initial data from the parser
    let draft: RecipeImportManager.RecipeImportDraft
    let prefetchedImage: UIImage?

    // Called with the saved recipe on success
    var onSave: (CloudRecipe) -> Void

    // MARK: - Wizard state

    @State private var step: Int = 1
    private let totalSteps = 4

    // Step 1 – Photo
    @State private var heroImage: UIImage?
    @State private var showPhotoSourcePicker = false
    @State private var showPhotoPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showCameraPicker = false

    // Step 2 – Ingredients
    @State private var ingredients: [RecipeImportManager.ImportedIngredient] = []

    // Step 3 – Pans
    @State private var availablePans: [CloudPan] = []
    @State private var selectedPans: [CloudPan] = []
    @State private var pansLoading = true
    @State private var customPanText = ""

    // Step 4 – Instructions
    @State private var steps: [RecipeStep] = []
    @State private var newStepText = ""

    // Save state
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveProgress: Double = 0
    @State private var saveProgressMessage = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    switch step {
                    case 1: photoStep
                    case 2: ingredientsStep
                    case 3: pansStep
                    case 4: instructionsStep
                    default: EmptyView()
                    }
                }
                .disabled(isSaving)

                if isSaving {
                    saveProgressPanel
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isSaving)
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .onAppear(perform: seedFromDraft)
        .onChange(of: prefetchedImage) { _, image in
            if heroImage == nil {
                heroImage = image
            }
        }
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload) {
                    heroImage = image
                }
                photosPickerItem = nil
            }
        }
    }

    // MARK: - Step titles

    private var stepTitle: String {
        switch step {
        case 1: return "Photo"
        case 2: return "Ingredients"
        case 3: return "Pans"
        case 4: return "Instructions"
        default: return ""
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if step > 1 {
                Button("Back") { step -= 1 }
                    .disabled(isSaving)
            } else {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            stepIndicator
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(1...totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Seed from draft

    private func seedFromDraft() {
        ingredients = draft.ingredients
        steps = stepsFromInstructions(draft.instructions)
        heroImage = prefetchedImage
    }

    private func stepsFromInstructions(_ raw: String) -> [RecipeStep] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                let stripped = line.replacingOccurrences(
                    of: #"^\s*\d+\s*[\.]\s*"#, with: "", options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? line : stripped
            }
            .filter { !$0.isEmpty }
            .map { RecipeStep(text: $0, timerSeconds: Self.parseTimer(from: $0)) }
    }

    // Extracts a duration in seconds from natural-language text.
    // Handles "20 minutes", "1 hour 30 mins", "45 secs", "10-12 minutes" (takes upper bound).
    nonisolated static func parseTimer(from text: String) -> Int? {
        let lower = text.lowercased()
        var total = 0

        let patterns: [(String, Int)] = [
            (#"(\d+)\s*(?:hours?|hrs?)"#, 3600),
            (#"(?:\d+-)?(\d+)\s*(?:minutes?|mins?)"#, 60),
            (#"(\d+)\s*(?:seconds?|secs?)"#, 1)
        ]

        for (pattern, multiplier) in patterns {
            if let re = try? NSRegularExpression(pattern: pattern),
               let match = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let range = Range(match.range(at: 1), in: lower),
               let value = Int(lower[range]) {
                total += value * multiplier
            }
        }

        return total > 0 ? total : nil
    }

    // MARK: - Step 1: Photo

    private var photoStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                wizardStageHeader

                Text("Recipe photo for \(draft.name)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                photoPreview

                VStack(spacing: 12) {
                    PhotosPicker(selection: $photosPickerItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showCameraPicker = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if heroImage != nil {
                        Button(role: .destructive) {
                            heroImage = nil
                        } label: {
                            Label("Remove Photo", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)

                nextButton(label: "Next: Ingredients", enabled: true) {
                    step = 2
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showCameraPicker) {
            ImagePickerController(sourceType: .camera) { image in
                if let img = image?.normalized() {
                    heroImage = img
                }
            }
        }
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let img = heroImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()
                .cornerRadius(16)
                .padding(.horizontal)
        } else if let url = draft.imageURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipped()
                        .cornerRadius(16)
                        .padding(.horizontal)
                        .task {
                            // Cache to state so user sees it instantly on re-visit
                        }
                case .empty:
                    placeholderPhoto
                case .failure:
                    placeholderPhoto
                @unknown default:
                    placeholderPhoto
                }
            }
        } else {
            placeholderPhoto
        }
    }

    private var placeholderPhoto: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.secondary.opacity(0.15))
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No photo found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
    }

    // MARK: - Step 2: Ingredients

    private var ingredientsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                wizardStageHeader
                    .padding(.horizontal)

                HStack {
                    Text("Confirm or edit the ingredients below.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(ingredients.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                ForEach(ingredients.indices, id: \.self) { idx in
                    ingredientRow(index: idx)
                        .padding(.horizontal)
                }

                Button {
                    ingredients.append(.init(name: "", quantity: nil, unit: nil, originalLine: ""))
                } label: {
                    Label("Add ingredient", systemImage: "plus.circle.fill")
                }
                .padding(.horizontal)
                .padding(.top, 4)

                nextButton(
                    label: "Next: Pans",
                    enabled: !ingredients.filter({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).isEmpty
                ) {
                    step = 3
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func ingredientRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ingredient", text: Binding(
                    get: { ingredients[safe: index]?.name ?? "" },
                    set: { if index < ingredients.count { ingredients[index].name = $0 } }
                ))
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)

                Button {
                    if index < ingredients.count { ingredients.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                        .font(.title3)
                }
            }

            HStack(spacing: 8) {
                TextField("Qty", text: Binding(
                    get: { ingredients[safe: index]?.quantity ?? "" },
                    set: { if index < ingredients.count { ingredients[index].quantity = $0.nilIfEmpty } }
                ))
                .keyboardType(.numbersAndPunctuation)
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)
                .frame(width: 80)

                TextField("Unit", text: Binding(
                    get: { ingredients[safe: index]?.unit ?? "" },
                    set: { if index < ingredients.count { ingredients[index].unit = $0.nilIfEmpty } }
                ))
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)
                .frame(width: 80)

                Spacer()

                Text(ingredients[safe: index]?.asAppIngredientLine() ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Step 3: Pans

    private var pansStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                wizardStageHeader
                    .padding(.horizontal)

                Text("Select the cookware this recipe needs (optional).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                if pansLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading pans…")
                        Spacer()
                    }
                    .padding()
                    .onAppear(perform: loadPans)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(availablePans) { pan in
                            Button {
                                togglePan(pan)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: pan.symbolName())
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 28)

                                    Text(pan.name)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    if selectedPans.contains(where: { $0.id == pan.id }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 56)
                        }
                    }
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Custom pan entry
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add custom pan")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)

                    HStack(spacing: 8) {
                        TextField("e.g. Dutch oven", text: $customPanText)
                            .padding(10)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(10)

                        Button {
                            let t = customPanText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            let pan = CloudPan(name: t)
                            selectedPans.append(pan)
                            customPanText = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal)
                }

                if !selectedPans.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        FlowLayout(items: selectedPans.map(\.name)) { name in
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.caption)
                                Button {
                                    selectedPans.removeAll { $0.name == name }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(20)
                        }
                        .padding(.horizontal)
                    }
                }

                nextButton(label: "Next: Instructions", enabled: true) {
                    step = 4
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func togglePan(_ pan: CloudPan) {
        if let idx = selectedPans.firstIndex(where: { $0.id == pan.id }) {
            selectedPans.remove(at: idx)
        } else {
            selectedPans.append(pan)
        }
    }

    private func loadPans() {
        let query = CKQuery(recordType: "Pan", predicate: NSPredicate(value: true))
        let db = CKContainer.default().publicCloudDatabase
        Task {
            do {
                let (records, _) = try await db.records(matching: query)
                let pans = records.compactMap { _, result -> CloudPan? in
                    guard case .success(let record) = result else { return nil }
                    return CloudPan(record: record)
                }
                await MainActor.run {
                    availablePans = pans
                    pansLoading = false
                }
            } catch {
                await MainActor.run { pansLoading = false }
            }
        }
    }

    // MARK: - Step 4: Instructions

    private var instructionsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                wizardStageHeader
                    .padding(.horizontal)

                Text("Confirm or edit the instructions.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                ForEach(steps.indices, id: \.self) { idx in
                    stepRow(index: idx)
                        .padding(.horizontal)
                }

                // New step entry
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Add a step…", text: $newStepText, axis: .vertical)
                            .lineLimit(2...4)
                            .padding(10)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(10)

                        Button {
                            let t = newStepText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            steps.append(RecipeStep(text: t, timerSeconds: Self.parseTimer(from: t)))
                            newStepText = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .padding(.horizontal)

                if let saveError {
                    Text(saveError)
                        .foregroundColor(.red)
                        .font(.callout)
                        .padding(.horizontal)
                }

                saveButton
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func stepRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .trailing)
                    .padding(.top, 10)

                TextField("Step \(index + 1)", text: Binding(
                    get: { steps[safe: index]?.text ?? "" },
                    set: { if index < steps.count { steps[index].text = $0 } }
                ), axis: .vertical)
                .lineLimit(2...6)
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)

                Button {
                    if index < steps.count { steps.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                        .font(.title3)
                }
                .padding(.top, 8)
            }

            stepTimerRow(index: index)
                .padding(.leading, 34)
        }
    }

    @ViewBuilder
    private func stepTimerRow(index: Int) -> some View {
        let secs = steps[safe: index]?.timerSeconds ?? 0
        if secs > 0 {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text(formatTimer(secs))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                Spacer()
                Button { if index < steps.count { steps[index].timerSeconds = max(0, secs - 300) } }
                    label: { Text("−5m").font(.caption) }
                Button { if index < steps.count { steps[index].timerSeconds = min(86400, secs + 300) } }
                    label: { Text("+5m").font(.caption) }
                Button { if index < steps.count { steps[index].timerSeconds = nil } }
                    label: { Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary) }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if index < steps.count { steps[index].timerSeconds = 300 }
            } label: {
                Label("Add timer", systemImage: "timer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func formatTimer(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    // MARK: - Save

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(isSaving ? "Saving…" : "Add Recipe")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(steps.isEmpty ? Color.secondary : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(isSaving)
    }

    private var saveProgressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving recipe")
                        .font(.subheadline.weight(.semibold))
                    Text(saveProgressMessage.isEmpty ? "Preparing recipe..." : saveProgressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(Int((saveProgress * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: saveProgress)
                .progressViewStyle(.linear)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    @MainActor
    private func save() async {
        saveError = nil
        saveProgress = 0.08
        saveProgressMessage = "Preparing ingredients and instructions..."
        isSaving = true
        defer {
            isSaving = false
            saveProgress = 0
            saveProgressMessage = ""
        }

        let ingredientLines = ingredients
            .map { $0.asAppIngredientLine() }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let panString = selectedPans.map(\.name).joined(separator: ", ")

        let instructionText = steps
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")

        let recipeSteps = steps

        saveProgress = 0.28
        saveProgressMessage = "Preparing recipe photo..."
        var finalImage: UIImage? = heroImage

        // If no manually chosen image, fall back to prefetch result or download now
        if finalImage == nil {
            finalImage = prefetchedImage
        }
        if finalImage == nil, let url = draft.imageURL {
            finalImage = try? await downloadImage(from: url)
        }

        saveProgress = 0.52
        saveProgressMessage = "Building recipe record..."
        let now = Date()
        let recipe = CloudRecipe(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            serves: "1",
            ingredients: ingredientLines,
            pan: panString,
            instructions: instructionText,
            steps: recipeSteps,
            image: finalImage,
            location: "Fridge",
            creationDate: now,
            modificationDate: now,
            imageSourceURL: draft.imageURL?.absoluteString
        )

        do {
            saveProgress = 0.72
            saveProgressMessage = "Uploading to iCloud..."
            let savedRecord = try await saveToCloudKit(recipe)
            let savedRecipe = CloudRecipe(from: savedRecord)
            RecipeListModel.cacheSavedRecipe(savedRecipe)
            saveProgress = 1
            saveProgressMessage = "Recipe saved. Updating your recipe list..."
            NotificationCenter.default.post(name: .recipeDidSave, object: savedRecipe)
            onSave(savedRecipe)
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func downloadImage(from url: URL) async throws -> UIImage? {
        // Retrying, connectivity-aware download with downsampled decoding
        // (orientation is applied during decode, so no `.normalized()` needed).
        try await RemoteImageFetcher.fetchImage(candidates: RemoteImageFetcher.wikimediaCandidates(for: url))
    }

    private func saveToCloudKit(_ recipe: CloudRecipe) async throws -> CKRecord {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let db = container.publicCloudDatabase

        let recordID = CKRecord.ID(recordName: recipe.id)
        let record = CKRecord(recordType: "Recipe", recordID: recordID)

        record["name"] = recipe.name as CKRecordValue
        record["serves"] = recipe.serves as CKRecordValue
        record["ingredients"] = recipe.ingredients as NSArray
        record["pan"] = recipe.pan as CKRecordValue
        record["instructions"] = recipe.instructions as CKRecordValue
        record["location"] = recipe.location as CKRecordValue
        record["dietaryTags"] = [] as NSArray

        if let data = try? JSONEncoder().encode(recipe.steps),
           let json = String(data: data, encoding: .utf8) {
            record["stepsJSON"] = json as CKRecordValue
        }

        if let image = recipe.image?.normalized(), let asset = image.toCKAsset() {
            record["image"] = asset
        }

        return try await db.save(record)
    }

    // MARK: - Shared next button

    private func nextButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: .infinity)
                .padding()
                .background(enabled ? Color.accentColor : Color.secondary)
                .foregroundColor(.white)
                .cornerRadius(14)
        }
        .disabled(!enabled)
    }

    private var wizardStageHeader: some View {
        HStack(spacing: 8) {
            ForEach(1...totalSteps, id: \.self) { index in
                VStack(spacing: 6) {
                    Image(systemName: stageIcon(for: index))
                        .font(.caption.weight(.semibold))
                    Text(stageShortTitle(for: index))
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(index == step ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(index == step ? Color.accentColor : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Import step \(step) of \(totalSteps): \(stepTitle)")
    }

    private func stageIcon(for index: Int) -> String {
        switch index {
        case 1: return "photo"
        case 2: return "list.bullet"
        case 3: return "frying.pan"
        case 4: return "text.alignleft"
        default: return "circle"
        }
    }

    private func stageShortTitle(for index: Int) -> String {
        switch index {
        case 1: return "Photo"
        case 2: return "Food"
        case 3: return "Pans"
        case 4: return "Steps"
        default: return ""
        }
    }
}

// MARK: - Flow layout for pan chips

private struct FlowLayout<Item, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        var currentRow: [Item] = []
        var rows: [[Item]] = []

        // Simple split into rows by count (real measurement would need GeometryReader)
        let rowSize = 3
        for (i, item) in items.enumerated() {
            currentRow.append(item)
            if currentRow.count == rowSize || i == items.count - 1 {
                rows.append(currentRow)
                currentRow = []
            }
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 8) {
                    ForEach(rows[rowIdx].indices, id: \.self) { colIdx in
                        content(rows[rowIdx][colIdx])
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
