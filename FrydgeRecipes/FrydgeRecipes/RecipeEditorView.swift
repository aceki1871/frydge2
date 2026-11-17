//
//  RecipeEditorView.swift
//  FrydgeRecipes
//
//  Updated: 13/01/2026
//  - Ingredients: removed blue tick + red minus buttons
//  - Tap an ingredient row to expand/collapse dropdown (Dietary Tags + Location)
//  - Auto-expands the first ingredient (import flow / first-time creation)
//  - Dietary tags + location are PER INGREDIENT and persisted to CloudKit (ingredientsMetaJSON)
//  - Recipe-level dietary badges at top are derived from per-ingredient tags (union), not globally applied
//

import SwiftUI
import PhotosUI
import CloudKit
import UIKit
import Foundation

// MARK: - UIImage -> CKAsset

extension UIImage {
    func toCKAsset() -> CKAsset? {
        // Every CKAsset the app uploads is pixel- and byte-bounded here
        // (recipes, community photos, offline sync). Orientation is baked in.
        guard let imageData = self.frydgeBoundedJPEG(maxPixelSize: ImageBudget.upload, quality: 0.8) else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try imageData.write(to: tempURL)
            return CKAsset(fileURL: tempURL)
        } catch {
            print("Error converting UIImage to CKAsset: \(error.localizedDescription)")
            return nil
        }
    }

    func normalized() -> UIImage {
        guard self.imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(self.size, false, self.scale)
        self.draw(in: CGRect(origin: .zero, size: self.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return normalizedImage
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}

struct RecipeEditorView: View {
    @Binding var recipe: CloudRecipe?
    @State private var isFrydge: Bool = true

    /// Optional draft coming from the import flow
    var importDraft: RecipeImportManager.RecipeImportDraft? = nil

    var onSave: (CloudRecipe?) -> Void

    @State private var name = ""

    // Serves counter (default 1)
    @State private var servesCount: Int = 1

    // Ingredient strings (kept for CloudRecipe compatibility)
    @State private var ingredients: [String] = []
    @State private var ingredientText = "" // kept for onAddToRecipe plumbing

    // ✅ Per-ingredient meta (tags + location) in parallel with `ingredients`
    @State private var ingredientMeta: [IngredientMeta] = []
    @State private var expandedIngredientIndex: Int? = nil
    @FocusState private var focusedIngredientIndex: Int?

    @State private var pan: [String] = []
    @State private var panText = ""

    /// Structured steps (instruction + optional timer + optional temperature)
    @State private var steps: [RecipeStep] = []
    @State private var stepText: String = ""

    // Timer input (for creating new step)
    @State private var stepMinutes: Int = 0
    @State private var stepSeconds: Int = 0

    // Temperature input (for creating new step)
    @State private var includeTemperature: Bool = false
    @State private var temperatureValue: Double = 180
    @State private var temperatureUnit: TemperatureUnit = .celsius

    // Reorder mode for steps
    @State private var stepsReorderMode: Bool = false

    @State private var images: [UIImage] = []
    @State private var showImagePicker = false
    @State private var imageSourceType: UIImagePickerController.SourceType = .photoLibrary
    @State private var saveButtonTitle = "Save"
    @State private var isSaving = false

    /// Editing someone else's recipe never touches their original: the save
    /// creates the current user's own copy ("version") under a fresh ID.
    private var isMakingVersion: Bool {
        recipe.map { !$0.isOwnedByCurrentUser } ?? false
    }
    @Environment(\.dismiss) private var dismiss
    @State private var existingAssets: [CKAsset] = []
    @State private var removedImages: [CKAsset] = []
    @State private var showRotationConfirmation = false
    @State private var tempImage: UIImage? = nil

    /// Recipe-level dietary tags (shown at top) — derived from ingredientMeta (union)
    @State private var dietaryTags: [String] = []

    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @EnvironmentObject var frydgeManager: FrydgeManager
    @State private var showProductDetails = false

    /// Prevent applying import draft multiple times
    @State private var didApplyImportDraft = false

    // ✅ Step editor sheet state
    @State private var editingStepIndex: Int? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if isMakingVersion {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You're making your own version")
                                .font(.subheadline.weight(.semibold))
                            Text("The original by \(recipe?.authorName ?? "its author") stays as it is. Your changes are saved as a new recipe under your name.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal)
                }
                recipeNameField
                servesSection
                ingredientsSection
                panSection
                stepsSection
                imagePickerSection

                Spacer(minLength: 24)
            }
            .onAppear {
                loadRecipeData()
                applyImportDraftIfNeeded()
                syncIngredientMetaIfNeeded()
                recomputeRecipeDietaryTagsFromMeta()
                clampExpandedIndexIfNeeded()
            }
            .onChange(of: ingredients.count) {
                syncIngredientMetaIfNeeded()
                recomputeRecipeDietaryTagsFromMeta()
                clampExpandedIndexIfNeeded()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePickerController(sourceType: imageSourceType) { image in
                    if let image = image {
                        images = [image]
                    }
                }
            }
            .sheet(isPresented: $showRotationConfirmation) {
                if let tempImage = tempImage {
                    RotationConfirmationView(image: .constant(tempImage)) { rotatedImage in
                        if let lastImageIndex = images.indices.last {
                            images[lastImageIndex] = rotatedImage
                        } else {
                            images.append(rotatedImage)
                        }
                        self.tempImage = nil
                        self.showRotationConfirmation = false
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { editingStepIndex != nil },
                set: { if !$0 { editingStepIndex = nil } }
            )) {
                if let idx = editingStepIndex, idx >= 0, idx < steps.count {
                    StepEditSheet(
                        step: steps[idx],
                        onSave: { updated in
                            steps[idx] = updated
                            editingStepIndex = nil
                        },
                        onCancel: {
                            editingStepIndex = nil
                        }
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    // MARK: - Ingredient Meta (Per Ingredient)

    private enum IngredientLocation: String, CaseIterable, Identifiable, Codable {
        case kitchen = "In your Kitchen"
        case shop = "Nip to Shop"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .kitchen: return "house"
            case .shop: return "cart"
            }
        }
    }

    private struct IngredientMeta: Hashable, Codable {
        var tags: Set<String> = []                 // DF/GF/V/VG per ingredient
        var location: IngredientLocation = .shop   // per ingredient
    }

    private let dietaryChoices: [String] = ["DF", "GF", "V", "VG"]

    private func syncIngredientMetaIfNeeded() {
        if ingredientMeta.count < ingredients.count {
            ingredientMeta.append(contentsOf: Array(repeating: IngredientMeta(), count: ingredients.count - ingredientMeta.count))
        } else if ingredientMeta.count > ingredients.count {
            ingredientMeta = Array(ingredientMeta.prefix(ingredients.count))
        }
    }

    private func clampExpandedIndexIfNeeded() {
        if let idx = expandedIngredientIndex, idx >= ingredients.count {
            expandedIngredientIndex = ingredients.isEmpty ? nil : max(0, ingredients.count - 1)
        }
    }

    private func toggleIngredientExpanded(_ index: Int) {
        if expandedIngredientIndex == index {
            expandedIngredientIndex = nil // collapse (acts as per-item "save")
        } else {
            expandedIngredientIndex = index
        }
    }

    private func recomputeRecipeDietaryTagsFromMeta() {
        syncIngredientMetaIfNeeded()

        var union = Set<String>()
        for m in ingredientMeta { union.formUnion(m.tags) }

        // Stable order: DF, GF, V, VG
        var ordered: [String] = []
        for t in dietaryChoices where union.contains(t) { ordered.append(t) }
        dietaryTags = ordered
    }

    // MARK: - Persist ingredient meta to CloudKit

    private func encodeIngredientsMetaJSON() -> String? {
        syncIngredientMetaIfNeeded()
        do {
            let data = try JSONEncoder().encode(ingredientMeta)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[ERROR] Failed to encode ingredientsMetaJSON: \(error)")
            return nil
        }
    }

    private func decodeIngredientsMetaJSON(_ json: String) -> [IngredientMeta]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([IngredientMeta].self, from: data)
        } catch {
            print("[ERROR] Failed to decode ingredientsMetaJSON: \(error)")
            return nil
        }
    }

    @MainActor
    private func loadIngredientMetaFromCloudKitIfPossible(recipeID: String) async {
        let containerID = "iCloud.com.Clark-Online.Recipe"
        let container = CKContainer(identifier: containerID)
        let db = container.publicCloudDatabase

        let recordID = CKRecord.ID(recordName: recipeID)

        do {
            let record = try await db.record(for: recordID)
            if let json = record["ingredientsMetaJSON"] as? String,
               let decoded = decodeIngredientsMetaJSON(json) {
                self.ingredientMeta = decoded
                syncIngredientMetaIfNeeded()
                recomputeRecipeDietaryTagsFromMeta()
            }
        } catch {
            // Silent by design (older records may not have this field)
        }
    }

    // MARK: - Temperature Unit

    private enum TemperatureUnit: String, CaseIterable, Identifiable {
        case celsius = "°C"
        case fahrenheit = "°F"
        var id: String { rawValue }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe == nil ? "Add Recipe" : "Edit Recipe")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 10)

                HStack(spacing: 6) {
                    if dietaryTags.contains("GF") { tagBadge("GF") }
                    if dietaryTags.contains("DF") { tagBadge("DF") }
                    if dietaryTags.contains("V")  { tagBadge("V") }
                    if dietaryTags.contains("VG") { tagBadge("VG") }
                }
            }

            Spacer()

            Button(action: saveRecipe) {
                Text(saveButtonTitle)
                    .font(.headline)
                    .foregroundColor(isSaving ? .gray : .blue)
            }
            .disabled(isSaving)
            .padding(.top, 16)
        }
    }

    // MARK: - Name

    private var recipeNameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NAME")
                .font(.caption)
                .foregroundColor(.gray)
            TextField("Recipe Name", text: $name)
                .padding()
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
        }
    }

    // MARK: - Serves

    private var servesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVES")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                Text("👤")
                    .font(.system(size: 28))

                Text("\(servesCount)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(minWidth: 28, alignment: .leading)

                Spacer()

                Button {
                    servesCount = max(1, servesCount - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)

                Button {
                    servesCount = min(50, servesCount + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.gray.opacity(0.15))
            .cornerRadius(8)
        }
    }

    // MARK: - Ingredients (Tap-to-expand dropdown)

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INGREDIENTS")
                .font(.caption)
                .foregroundColor(.gray)

            if ingredients.isEmpty {
                Text("No ingredients yet.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ForEach(ingredients.indices, id: \.self) { index in
                    ingredientDropdownRow(index: index)
                }
            }

            HStack {
                Spacer()

                Button(action: { showProductDetails = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.blue)
                        .accessibilityLabel("Add ingredient")
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 6)
        }
        .sheet(isPresented: $showProductDetails) {
            ProductDetailsView(
                isShowing: $showProductDetails,
                productDetails: nil,
                context: .recipe,
                onAddToRecipe: { formatted in
                    self.ingredientText = formatted
                    self.addIngredientFromText()
                }
            )
            .environmentObject(shoppingListManager)
            .environmentObject(frydgeManager)
        }
    }

    @ViewBuilder
    private func ingredientDropdownRow(index: Int) -> some View {
        let _ = syncIngredientMetaIfNeeded()   // ✅ allowed inside ViewBuilder (not a View)
        if index < ingredients.count, index < ingredientMeta.count {
        let isExpanded = expandedIngredientIndex == index

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(
                    "Ingredient",
                    text: Binding(
                        get: { ingredients[index] },
                        set: { ingredients[index] = $0 }
                    )
                )
                .focused($focusedIngredientIndex, equals: index)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(10)

                Button {
                    focusedIngredientIndex = nil
                    toggleIngredientExpanded(index)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    removeIngredient(at: index)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if focusedIngredientIndex != index {
                    toggleIngredientExpanded(index)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {

                    // Dietary tags (per ingredient)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dietary Tags (this ingredient)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            ForEach(dietaryChoices, id: \.self) { tag in
                                let selected = ingredientMeta[index].tags.contains(tag)
                                Button {
                                    if selected {
                                        ingredientMeta[index].tags.remove(tag)
                                    } else {
                                        ingredientMeta[index].tags.insert(tag)
                                    }
                                    recomputeRecipeDietaryTagsFromMeta()
                                } label: {
                                    Text(tag)
                                        .font(.caption.weight(.semibold))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(selected ? Color.blue : Color.gray.opacity(0.15))
                                        .foregroundColor(selected ? .white : .primary)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Location (per ingredient)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Location (this ingredient)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker(
                            selection: Binding(
                                get: { ingredientMeta[index].location },
                                set: { ingredientMeta[index].location = $0 }
                            ),
                            label: HStack(spacing: 8) {
                                Image(systemName: ingredientMeta[index].location.systemImage)
                                Text(ingredientMeta[index].location.rawValue)
                            }
                        ) {
                            ForEach(IngredientLocation.allCases) { loc in
                                Text(loc.rawValue).tag(loc)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Text("Tap the ingredient name again to minimise.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                )
            }
        }
        .padding(.vertical, 6)
        } // end bounds guard
    }

    private func addIngredientFromText() {
        let cleaned = ingredientText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed

        guard !cleaned.isEmpty else { return }

        ingredients.append(cleaned)
        ingredientMeta.append(IngredientMeta())

        ingredientText = ""

        if ingredients.count == 1 {
            expandedIngredientIndex = 0
        }

        recomputeRecipeDietaryTagsFromMeta()
    }

    private func removeIngredient(at index: Int) {
        guard index >= 0, index < ingredients.count else { return }

        // Collapse / adjust expanded state
        if let expanded = expandedIngredientIndex {
            if expanded == index {
                expandedIngredientIndex = nil
            } else if expanded > index {
                expandedIngredientIndex = expanded - 1
            }
        }

        // Adjust focus if needed
        if let focused = focusedIngredientIndex {
            if focused == index {
                focusedIngredientIndex = nil
            } else if focused > index {
                focusedIngredientIndex = focused - 1
            }
        }

        ingredients.remove(at: index)
        if index < ingredientMeta.count {
            ingredientMeta.remove(at: index)
        }

        syncIngredientMetaIfNeeded()
        recomputeRecipeDietaryTagsFromMeta()
        clampExpandedIndexIfNeeded()
    }

    // MARK: - Pan

    private var panSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAN")
                .font(.caption)
                .foregroundColor(.gray)

            ForEach(pan.indices, id: \.self) { index in
                HStack {
                    TextField("Edit Pan", text: Binding(
                        get: { self.pan[index] },
                        set: { self.pan[index] = $0 }
                    ))
                    .padding(8)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)

                    Button(action: { updatePan(at: index) }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                    }

                    Button(action: { removePan(at: index) }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            }

            HStack {
                TextField("Add Pan", text: $panText)
                    .padding()
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)
                Button(action: addPan) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }
            }
        }
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("INSTRUCTIONS (STEPS)")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer()

                Button {
                    stepsReorderMode.toggle()
                } label: {
                    Text(stepsReorderMode ? "Done" : "Reorder")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Add step (e.g. Preheat oven to 200°C)", text: $stepText, axis: .vertical)
                    .lineLimit(2...5)
                    .padding()
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)

                HStack(spacing: 10) {
                    Stepper("Min: \(stepMinutes)", value: $stepMinutes, in: 0...240)
                    Stepper("Sec: \(stepSeconds)", value: $stepSeconds, in: 0...59)
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Include temperature", isOn: $includeTemperature)

                    if includeTemperature {
                        HStack(spacing: 10) {
                            Picker("Unit", selection: $temperatureUnit) {
                                ForEach(TemperatureUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)

                            Text("\(Int(temperatureValue))\(temperatureUnit.rawValue)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Spacer()
                        }

                        Slider(
                            value: $temperatureValue,
                            in: temperatureUnit == .celsius ? 0...260 : 32...500,
                            step: 1
                        )
                    }
                }
                .padding(.top, 2)

                Button(action: addStep) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Step")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(stepText.trimmed.isEmpty)
            }

            if steps.isEmpty {
                Text("No steps yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { idx, s in
                        stepRow(index: idx, step: s)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingStepIndex = idx
                            }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func stepRow(index idx: Int, step s: RecipeStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(idx + 1).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(s.text)
                    .foregroundColor(.primary)

                Spacer()

                HStack(spacing: 10) {
                    if let secs = s.timerSeconds, secs > 0 {
                        Image(systemName: "timer")
                            .foregroundColor(.secondary)
                    }
                    if let tv = s.temperatureValue, let _ = s.temperatureUnit, tv > 0 {
                        Image(systemName: "thermometer")
                            .foregroundColor(.secondary)
                    }
                }

                Button(role: .destructive) {
                    steps.remove(at: idx)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }

                if stepsReorderMode {
                    VStack(spacing: 8) {
                        Button { moveStep(from: idx, to: idx - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(idx == 0)

                        Button { moveStep(from: idx, to: idx + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(idx == steps.count - 1)
                    }
                    .foregroundColor(.blue)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            if let secs = s.timerSeconds, secs > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "timer").foregroundColor(.secondary)
                    Text(formatTimer(secs)).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            }

            if let tv = s.temperatureValue, let tu = s.temperatureUnit, tv > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer").foregroundColor(.secondary)
                    Text("\(tv)\(tu)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private func moveStep(from: Int, to: Int) {
        guard from >= 0, from < steps.count else { return }
        guard to >= 0, to < steps.count else { return }
        let item = steps.remove(at: from)
        steps.insert(item, at: to)
    }

    private func addStep() {
        let cleanText = stepText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
        guard !cleanText.isEmpty else { return }

        let total = (stepMinutes * 60) + stepSeconds
        let timer: Int? = total > 0 ? total : nil

        let temp: Int? = includeTemperature ? Int(temperatureValue.rounded()) : nil
        let unit: String? = includeTemperature ? temperatureUnit.rawValue : nil

        steps.append(
            RecipeStep(
                text: cleanText,
                timerSeconds: timer,
                mediaURLString: nil,
                temperatureValue: temp,
                temperatureUnit: unit
            )
        )

        stepText = ""
        stepMinutes = 0
        stepSeconds = 0
        includeTemperature = false
    }

    private func formatTimer(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let mins = s / 60
        let secs = s % 60
        if mins > 0 && secs > 0 { return "\(mins)m \(secs)s" }
        if mins > 0 { return "\(mins)m" }
        return "\(secs)s"
    }

    private func encodeStepsJSON(_ steps: [RecipeStep]) -> String? {
        do {
            let data = try JSONEncoder().encode(steps)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[ERROR] Failed to encode steps JSON: \(error)")
            return nil
        }
    }

    // MARK: - Image

    private var imagePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMAGE")
                .font(.caption)
                .foregroundColor(.gray)

            if let image = images.first {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button(action: { images.removeAll() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .background(Color.white.opacity(0.7))
                            .clipShape(Circle())
                    }
                    .padding(4)
                }
            } else {
                Button(action: { showImagePicker = true }) {
                    Text("Add Image")
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.top, 8)
    }

    private func tagBadge(_ tag: String) -> some View {
        Text(tag)
            .font(.caption)
            .padding(5)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(5)
    }

    // MARK: - Import Draft Prefill

    private func applyImportDraftIfNeeded() {
        guard !didApplyImportDraft else { return }
        guard recipe == nil else { return } // only on new recipe
        guard let d = importDraft else { return }

        didApplyImportDraft = true

        if name.trimmed.isEmpty {
            name = d.name.trimmed
        }

        if ingredients.isEmpty {
            ingredients = d.ingredients
                .map { $0.asAppIngredientLine() }
                .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed }
                .filter { !$0.isEmpty }

            ingredientMeta = Array(repeating: IngredientMeta(), count: ingredients.count)

            if !ingredients.isEmpty {
                expandedIngredientIndex = 0
            }
        }

        if steps.isEmpty {
            let importedSteps = stepsFromImportedInstructions(d.instructions)
            if !importedSteps.isEmpty {
                steps = importedSteps
            }
        }

        servesCount = max(1, servesCount)
    }

    private func stepsFromImportedInstructions(_ instructions: String) -> [RecipeStep] {
        let raw = instructions.trimmed
        guard !raw.isEmpty else { return [] }

        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }

        let cleaned: [String] = lines.map { line in
            let stripped = line.replacingOccurrences(
                of: #"^\s*\d+\s*[\.\)]\s*"#,
                with: "",
                options: .regularExpression
            )
            return stripped.trimmed.isEmpty ? line : stripped.trimmed
        }

        let finalLines = cleaned.filter { !$0.isEmpty }
        return finalLines.map {
            RecipeStep(
                text: $0,
                timerSeconds: nil,
                mediaURLString: nil,
                temperatureValue: nil,
                temperatureUnit: nil
            )
        }
    }

    @MainActor
    private func ensureStepsForImportedRecipeIfNeeded() -> Bool {
        if !steps.isEmpty { return true }
        guard let d = importDraft else { return false }

        let imported = stepsFromImportedInstructions(d.instructions)
        if !imported.isEmpty {
            steps = imported
            return true
        }

        steps = [
            RecipeStep(
                text: "Imported recipe — add instructions here",
                timerSeconds: nil,
                mediaURLString: nil,
                temperatureValue: nil,
                temperatureUnit: nil
            )
        ]
        return true
    }

    // MARK: - Load

    private func loadImage(from url: URL) {
        DispatchQueue.global().async {
            if let data = try? Data(contentsOf: url),
               let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.display) {
                DispatchQueue.main.async {
                    self.images = [image]
                }
            }
        }
    }
    private func downloadImageIfNeeded(from url: URL) async -> UIImage? {
        // Shared image pipeline: retries, waits for connectivity, Wikimedia
        // thumbnail first, downsampled + orientation-corrected decode.
        try? await RemoteImageFetcher.fetchImage(candidates: RemoteImageFetcher.wikimediaCandidates(for: url))
    }

    private func loadRecipeData() {
        if let existingRecipe = recipe {
            if !existingRecipe.isOwnedByCurrentUser {
                saveButtonTitle = "Save My Version"
            }
            name = existingRecipe.name
            ingredients = existingRecipe.ingredients
            pan = existingRecipe.pan.split(separator: ",").map { String($0) }

            // Default meta; then attempt to load from CK field
            ingredientMeta = Array(repeating: IngredientMeta(), count: ingredients.count)

            dietaryTags = existingRecipe.dietaryTags
            steps = existingRecipe.steps

            if let s = Int(existingRecipe.serves) {
                servesCount = max(1, s)
            } else {
                servesCount = 1
            }

            if let imageAsset = existingRecipe.imageAsset, let fileURL = imageAsset.fileURL,
               FileManager.default.fileExists(atPath: fileURL.path) {
                loadImage(from: fileURL)
            } else {
                // The prefetch/loader cache lives in Documents/recipe-images;
                // the bare Documents path is the legacy location.
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let filename = "\(existingRecipe.id).jpg"
                let candidates = [
                    documents.appendingPathComponent("recipe-images", isDirectory: true).appendingPathComponent(filename),
                    documents.appendingPathComponent(filename)
                ]
                if let fileURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    loadImage(from: fileURL)
                } else if let urlString = existingRecipe.imageSourceURL, let remoteURL = URL(string: urlString) {
                    // Nothing on disk yet (fresh install): fetch the remote photo
                    // so the editor doesn't open with an empty image slot.
                    Task {
                        if let image = await downloadImageIfNeeded(from: remoteURL) {
                            await MainActor.run { if images.isEmpty { images = [image] } }
                        }
                    }
                } else {
                    print("[WARN] No local image found for recipe ID \(existingRecipe.id)")
                }
            }

            Task { await loadIngredientMetaFromCloudKitIfPossible(recipeID: existingRecipe.id) }
        } else {
            servesCount = 1
        }
    }

    // MARK: - Save

    private func saveRecipe() {
        guard !name.trimmed.isEmpty else {
            print("[ERROR] Recipe name cannot be empty.")
            return
        }

        if steps.isEmpty {
            let ok = ensureStepsForImportedRecipeIfNeeded()
            if !ok {
                print("[ERROR] Add at least one instruction step before saving.")
                return
            }
        }

        syncIngredientMetaIfNeeded()
        recomputeRecipeDietaryTagsFromMeta()

        // ✅ Because we may need to await an image download
        Task { @MainActor in
            // Owner edits keep the record ID (update in place). Anyone else's
            // edit becomes a brand-new recipe authored by them; the original is
            // never written to.
            let editingOwnRecipe = recipe.map { $0.isOwnedByCurrentUser } ?? false
            let recipeID = editingOwnRecipe ? (recipe?.id ?? UUID().uuidString) : UUID().uuidString
            let author: String = editingOwnRecipe
                ? (recipe?.authorName ?? RecipeAuthor.currentName)
                : RecipeAuthor.currentName
            let normalizedTags = Array(Set(dietaryTags.map { $0.trimmed.uppercased() }))

            // ✅ Start with whatever the user picked in the editor
            var finalImage: UIImage? = images.first

            // ✅ If no user image, try pull from imported draft image URL
            if finalImage == nil, let url = importDraft?.imageURL {
                finalImage = await downloadImageIfNeeded(from: url)
                if let finalImage {
                    // show it in the editor UI too
                    images = [finalImage]
                }
            }

            // ✅ Build recipe INCLUDING the imageSourceURL so it persists even if download fails
            let currentRecipe = CloudRecipe(
                name: name.trimmed,
                serves: String(servesCount),
                ingredients: ingredients,
                pan: pan.joined(separator: ", "),
                instructions: "",
                steps: steps,
                image: finalImage,
                id: recipeID,
                location: isFrydge ? "Fridge" : "Freezer",
                dietaryTags: normalizedTags,
                imageSourceURL: importDraft?.imageURL?.absoluteString ?? recipe?.imageSourceURL,
                authorName: author
            )

            isSaving = true
            saveButtonTitle = "Saving..."

            saveToCloudKit(currentRecipe) { result in
                DispatchQueue.main.async {
                    self.isSaving = false
                    switch result {
                    case .success:
                        self.saveButtonTitle = "Saved"
                        NotificationCenter.default.post(name: .recipeDidSave, object: currentRecipe.id)
                        self.onSave(currentRecipe)
                        self.dismiss()
                    case .failure(let error):
                        print("[ERROR] Failed to save recipe: \(error.localizedDescription)")
                        self.saveButtonTitle = "Save"
                    }
                }
            }
        }
    }

    private func saveToCloudKit(_ recipe: CloudRecipe, completion: @escaping (Result<Void, Error>) -> Void) {
        let containerID = "iCloud.com.Clark-Online.Recipe"
        let container = CKContainer(identifier: containerID)
        let db = container.publicCloudDatabase

        let recordID = CKRecord.ID(recordName: recipe.id)
        let record = CKRecord(recordType: "Recipe", recordID: recordID)

        record["name"] = recipe.name as CKRecordValue
        record["ingredients"] = recipe.ingredients as NSArray
        record["pan"] = recipe.pan as CKRecordValue
        record["dietaryTags"] = recipe.dietaryTags as NSArray
        record["instructions"] = "" as CKRecordValue
        record["serves"] = String(servesCount) as CKRecordValue
        if let author = recipe.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            record["authorName"] = author as CKRecordValue
        }
        if let source = recipe.imageSourceURL, !source.isEmpty {
            record["imageSourceURL"] = source as CKRecordValue
        }

        if let json = encodeStepsJSON(recipe.steps) {
            record["stepsJSON"] = json as CKRecordValue
        } else {
            record["stepsJSON"] = nil
        }

        // ✅ Persist per-ingredient meta
        if let metaJSON = encodeIngredientsMetaJSON() {
            record["ingredientsMetaJSON"] = metaJSON as CKRecordValue
        }

        if let image = images.first, let asset = image.toCKAsset() {
            record["image"] = asset
        }

        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys

        op.modifyRecordsResultBlock = { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }

        db.add(op)
    }

    // MARK: - Pan Helpers

    private func addPan() {
        guard !panText.trimmed.isEmpty else { return }
        pan.append(panText.trimmed)
        panText = ""
    }

    private func updatePan(at index: Int) {
        updateRecipeField(field: "pan", value: pan.joined(separator: ", "))
    }

    private func removePan(at index: Int) {
        pan.remove(at: index)
    }

    private func updateRecipeField(field: String, value: Any) {
        // Live field writes only make sense on a recipe we own; a version is
        // written in full when the user saves.
        guard let existing = recipe, existing.isOwnedByCurrentUser else { return }
        let recipeID = existing.id
        var update: [String: Any] = [:]
        update[field] = value
        Networking.shared.updateRecipeFields(recipeID: recipeID, fields: update) { result in
            switch result {
            case .success:
                print("[INFO] \(field.capitalized) updated successfully.")
            case .failure(let error):
                print("[ERROR] Failed to update \(field): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Step Edit Sheet

private struct StepEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var timerSeconds: Int
    @State private var includeTemp: Bool
    @State private var tempValue: Int
    @State private var tempUnit: String

    let original: RecipeStep
    let onSave: (RecipeStep) -> Void
    let onCancel: () -> Void

    init(step: RecipeStep, onSave: @escaping (RecipeStep) -> Void, onCancel: @escaping () -> Void) {
        self.original = step
        self.onSave = onSave
        self.onCancel = onCancel

        _text = State(initialValue: step.text)
        _timerSeconds = State(initialValue: max(0, step.timerSeconds ?? 0))

        if let tv = step.temperatureValue, let tu = step.temperatureUnit, tv > 0 {
            _includeTemp = State(initialValue: true)
            _tempValue = State(initialValue: tv)
            _tempUnit = State(initialValue: tu)
        } else {
            _includeTemp = State(initialValue: false)
            _tempValue = State(initialValue: 180)
            _tempUnit = State(initialValue: "°C")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Step text", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                }

                Section("Timer") { timerRow }

                Section("Temperature") {
                    Toggle("Include temperature", isOn: $includeTemp)
                    if includeTemp { tempRow }
                }
            }
            .navigationTitle("Edit Step")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let updated = RecipeStep(
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            timerSeconds: timerSeconds > 0 ? timerSeconds : nil,
                            mediaURLString: original.mediaURLString,
                            temperatureValue: includeTemp ? max(0, tempValue) : nil,
                            temperatureUnit: includeTemp ? tempUnit : nil
                        )
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var timerRow: some View {
        let mins = timerSeconds / 60
        let secs = timerSeconds % 60

        return HStack(spacing: 12) {
            Image(systemName: "timer")
                .foregroundColor(.secondary)

            Text("\(mins)m \(secs)s")
                .monospacedDigit()

            Spacer()

            Button { timerSeconds = max(0, timerSeconds - 60) } label: { Image(systemName: "minus.circle.fill") }
            Button { timerSeconds = min(24 * 60 * 60, timerSeconds + 60) } label: { Image(systemName: "plus.circle.fill") }
            Button { timerSeconds = max(0, timerSeconds - 15) } label: { Text("-15s") }
            Button { timerSeconds = min(24 * 60 * 60, timerSeconds + 15) } label: { Text("+15s") }
        }
        .buttonStyle(.plain)
    }

    private var tempRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer")
                .foregroundColor(.secondary)

            Picker("Unit", selection: $tempUnit) {
                Text("°C").tag("°C")
                Text("°F").tag("°F")
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            Text("\(tempValue)\(tempUnit)")
                .monospacedDigit()
                .foregroundColor(.secondary)

            Spacer()

            Button { tempValue = max(0, tempValue - 5) } label: { Image(systemName: "minus.circle.fill") }
            Button { tempValue = min(500, tempValue + 5) } label: { Image(systemName: "plus.circle.fill") }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ImagePickerController

struct ImagePickerController: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    var onImagePicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePickerController

        init(_ parent: ImagePickerController) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onImagePicked(image)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImagePicked(nil)
            picker.dismiss(animated: true)
        }
    }
}
