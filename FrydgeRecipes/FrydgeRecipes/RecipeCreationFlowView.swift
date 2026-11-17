//
//  RecipeCreationFlowView.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/01/2026.
//


//  RecipeCreationFlowView.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/01/2026.
//

import SwiftUI
import PhotosUI
import UIKit

/// Multi-step recipe creation flow:
/// Photo → Name → Ingredients → Steps (instruction + optional timer) → Overview (reorder) → Save
///
/// This view does NOT save to CloudKit.
/// You pass the completed draft back via `onComplete` and then call your existing save pipeline
/// (e.g. RecipeEditorView / CloudRecipe.saveNewRecipe / Firebase image upload etc).
struct RecipeCreationFlowView: View {

    enum Stage: Int, CaseIterable {
        case photo = 0
        case name
        case ingredients
        case steps
        case overview

        var title: String {
            switch self {
            case .photo: return "Photo"
            case .name: return "Name"
            case .ingredients: return "Ingredients"
            case .steps: return "Instructions"
            case .overview: return "Overview"
            }
        }
    }

    // MARK: - Inputs

    var onCancel: (() -> Void)? = nil
    var onComplete: ((RecipeDraft) -> Void)? = nil

    // MARK: - State

    @State private var stage: Stage = .photo
    @State private var draft: RecipeDraft = RecipeDraft()

    // Photo picking
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showCamera = false

    // Ingredients
    @State private var ingredientText: String = ""

    // Steps
    @State private var stepText: String = ""
    @State private var stepMinutes: Int = 0
    @State private var stepSeconds: Int = 0

    // Reorder (Overview)
    @State private var editMode: EditMode = .inactive
    @State private var showCookPreview = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                headerProgress

                Group {
                    switch stage {
                    case .photo:
                        photoStage
                    case .name:
                        nameStage
                    case .ingredients:
                        ingredientsStage
                    case .steps:
                        stepsStage
                    case .overview:
                        overviewStage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                footerNav
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .navigationTitle(stage.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel?() }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showCamera) {
                CameraImagePicker(image: $draft.image)
                    .ignoresSafeArea()
            }
            .onChange(of: photosPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedPhoto(newItem) }
            }
            .sheet(isPresented: $showCookPreview) {
                CookAlongView(
                    name: draft.name.isEmpty ? "Recipe Preview" : draft.name,
                    steps: draft.steps
                )
            }
        }
    }

    // MARK: - UI Pieces

    private var headerProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Create Recipe")
                    .font(.headline)
                Spacer()
                Text("\(stage.rawValue + 1)/\(Stage.allCases.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(stage.rawValue + 1), total: Double(Stage.allCases.count))
        }
    }

    private var footerNav: some View {
        HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(stage == .photo)

            Button {
                goNextOrSave()
            } label: {
                HStack(spacing: 8) {
                    Text(primaryCTA)
                    Image(systemName: stage == .overview ? "checkmark" : "chevron.right")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canProceedCurrentStage)
        }
    }

    private var primaryCTA: String {
        stage == .overview ? "Save" : "Next"
    }

    private var canProceedCurrentStage: Bool {
        switch stage {
        case .photo:
            // Allow skipping photo
            return true
        case .name:
            return draft.canProceedFromName
        case .ingredients:
            return !draft.ingredients.isEmpty
        case .steps:
            return !draft.steps.isEmpty
        case .overview:
            return draft.canSave
        }
    }

    // MARK: - Stages

    private var photoStage: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: 240)

                if let img = draft.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera")
                            .font(.system(size: 34, weight: .semibold))
                        Text("Add a photo (optional)")
                            .font(.headline)
                        Text("You can do this later too.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $photosPickerItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Photos")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showCamera = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                        Text("Camera")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if draft.image != nil {
                Button(role: .destructive) {
                    draft.image = nil
                } label: {
                    Text("Remove photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
    }

    private var nameStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipe name")
                .font(.headline)

            TextField("e.g. Steak & Rice", text: $draft.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .textFieldStyle(.roundedBorder)

            Text("Tip: keep it short. You can refine it later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var ingredientsStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add ingredients")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("e.g. Cheese 1kg", text: $ingredientText)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)

                Button {
                    addIngredientFromText()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .disabled(ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if draft.ingredients.isEmpty {
                Text("Add at least one ingredient to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(draft.ingredients, id: \.self) { item in
                        Text(item)
                    }
                    .onDelete { indexSet in
                        draft.ingredients.remove(atOffsets: indexSet)
                    }
                }
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer(minLength: 0)
        }
    }

    private var stepsStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add instruction steps")
                .font(.headline)

            TextField("e.g. Preheat oven to 200°C", text: $stepText, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Timer (optional)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Stepper("Min: \(stepMinutes)", value: $stepMinutes, in: 0...240)
                        Stepper("Sec: \(stepSeconds)", value: $stepSeconds, in: 0...59)
                    }
                    .font(.subheadline)
                }

                Spacer()

                Button {
                    addStepFromInputs()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("Add step")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(stepText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if draft.steps.isEmpty {
                Text("Add at least one step to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(draft.steps) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.text)
                                .font(.body)
                            if let t = s.timerDisplay {
                                Text("Timer: \(t)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { idx in
                        draft.steps.remove(atOffsets: idx)
                    }
                }
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer(minLength: 0)
        }
    }

    private var overviewStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.headline)

            // Summary
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(draft.name.isEmpty ? "Unnamed Recipe" : draft.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(draft.ingredients.count) ingredients")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("\(draft.steps.count) steps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))

            HStack(spacing: 10) {
                Button {
                    editMode = (editMode == .active) ? .inactive : .active
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(editMode == .active ? "Done Reorder" : "Reorder Steps")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showCookPreview = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                        Text("Preview Cook Mode")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(draft.steps.isEmpty)
            }

            Text("Steps")
                .font(.headline)

            List {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.text)
                            if let t = step.timerDisplay {
                                Text("Timer: \(t)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    draft.steps.move(fromOffsets: from, toOffset: to)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Flow control

    private func goBack() {
        guard let prev = Stage(rawValue: stage.rawValue - 1) else { return }
        editMode = .inactive
        stage = prev
    }

    private func goNextOrSave() {
        if stage == .overview {
            editMode = .inactive
            onComplete?(draft)
            return
        }
        guard let next = Stage(rawValue: stage.rawValue + 1) else { return }
        editMode = .inactive
        stage = next
    }

    // MARK: - Ingredients

    private func addIngredientFromText() {
        let clean = ingredientText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else { return }

        // De-dupe by case-insensitive match
        if !draft.ingredients.contains(where: { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == clean.lowercased() }) {
            draft.ingredients.append(clean)
        }

        ingredientText = ""
    }

    // MARK: - Steps

    private func addStepFromInputs() {
        let cleanText = stepText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        let seconds = (stepMinutes * 60) + stepSeconds
        let timer: Int? = seconds > 0 ? seconds : nil

        draft.steps.append(RecipeStep(text: cleanText, timerSeconds: timer))

        // Reset inputs
        stepText = ""
        stepMinutes = 0
        stepSeconds = 0
    }

    // MARK: - Photo load

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload) {
                await MainActor.run {
                    self.draft.image = image
                }
            }
        } catch {
            // best-effort
        }
    }
}

// MARK: - Camera Picker (UIKit)

private struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker
        init(parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}