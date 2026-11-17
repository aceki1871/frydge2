//
//  RecipeSnapView.swift
//  FrydgeRecipes
//
//  One-tap "snap a recipe" import. The camera opens straight away, the page is
//  read with on-device OCR, and the result card immediately shows whether the
//  recipe can be made from the frydge and roughly what it will cost. Saving is
//  one more tap; the full wizard is only a fallback for fixing details.
//

import SwiftUI
import PhotosUI
import Vision
import VisionKit
import CloudKit
import UIKit

struct RecipeSnapView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @StateObject private var costEstimator = RecipeCostEstimator()

    /// Called after a successful save so the presenter can navigate or dismiss.
    var onSaved: ((CloudRecipe) -> Void)? = nil

    private enum Stage: Equatable {
        case capturing
        case processing
        case review
        case failed(String)
    }

    @State private var stage: Stage = .capturing

    // Capture
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var heroPickerItem: PhotosPickerItem?
    @State private var processingImage: UIImage?

    // Result
    @State private var draft: RecipeImportManager.RecipeImportDraft?
    @State private var heroImage: UIImage?
    @State private var recipeName = ""
    @State private var serves = "4"
    @State private var readiness: RecipeReadiness.Summary?
    /// Parsed once per scan; the card reads this several times per render.
    @State private var stepLines: [String] = []
    @State private var stepsExpanded = false

    // Save / actions
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var addedMissingToList = false
    @State private var showWizard = false

    var body: some View {
        Group {
            switch stage {
            case .capturing:
                captureStage
            case .processing:
                processingStage
            case .review:
                NavigationStack { reviewStage }
            case .failed(let message):
                NavigationStack { failedStage(message) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPickedPages(items) }
        }
        .onChange(of: heroPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPickedHero(item) }
        }
        .onChange(of: frydgeManager.storedIngredients) { _, _ in refreshReadiness() }
        .fullScreenCover(isPresented: $showWizard) {
            if let editedDraft {
                RecipeImportWizardView(draft: editedDraft, prefetchedImage: heroImage) { saved in
                    showWizard = false
                    finish(saved)
                }
            }
        }
        .onDisappear { costEstimator.cancel() }
    }

    // MARK: - Capture

    @ViewBuilder
    private var captureStage: some View {
        if VNDocumentCameraViewController.isSupported {
            RecipeSnapDocumentCamera(
                onScan: { pages in Task { await process(pages: pages) } },
                onCancel: { cancelCapture() }
            )
            .ignoresSafeArea()
        } else {
            NavigationStack {
                VStack(spacing: 18) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("The document camera isn't available on this device.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Choose a photo of the recipe", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle("Snap a Recipe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { cancelCapture() }
                    }
                }
            }
        }
    }

    private func cancelCapture() {
        if draft != nil {
            stage = .review
        } else {
            dismiss()
        }
    }

    // MARK: - Processing

    private var processingStage: some View {
        ZStack {
            if let processingImage {
                Image(uiImage: processingImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 18)
                    .overlay(Color.black.opacity(0.45).ignoresSafeArea())
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Reading the recipe…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Finding ingredients, method, and checking your frydge")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding()
        }
    }

    // MARK: - Failed

    private func failedStage(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No recipe found")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                stage = .capturing
            } label: {
                Label("Try again", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showPhotoPicker = true
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle("Snap a Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: - Review

    private var reviewStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroSection
                titleSection
                readinessCard
                costCard
                ingredientsSection
                stepsSection
                actionButtons

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .disabled(isSaving)
        .navigationTitle("Snap a Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    stage = .capturing
                } label: {
                    Label("Rescan", systemImage: "camera.viewfinder")
                }
            }
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomTrailing) {
            if let heroImage {
                Image(uiImage: heroImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 160)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.title)
                            Text("Add a photo of the dish")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
            }

            PhotosPicker(selection: $heroPickerItem, matching: .images) {
                Label(heroImage == nil ? "Add photo" : "Change", systemImage: "photo")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Recipe name", text: $recipeName)
                .font(.title2.weight(.bold))
                .textInputAutocapitalization(.words)

            HStack(spacing: 8) {
                chip(systemImage: "person.2", text: "Serves \(serves)")
                chip(systemImage: "list.bullet", text: "\(draft?.ingredients.count ?? 0) ingredients")
                chip(systemImage: "text.badge.checkmark", text: "\(stepLines.count) steps")
            }
        }
    }

    private func chip(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(.secondary)
    }

    private var readinessCard: some View {
        let summary = readiness
        let canMake = summary?.canMakeNow ?? false
        let tint: Color = canMake ? .green : .orange

        return HStack(spacing: 14) {
            Image(systemName: canMake ? "checkmark.seal.fill" : "basket.fill")
                .font(.title)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary?.headline ?? "Checking your frydge…")
                    .font(.headline)
                Text(summary?.detail ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var costCard: some View {
        let statuses = readiness?.statuses ?? []
        let totals = costEstimator.totals(for: statuses)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("Cost to make")
                    .font(.headline)
                Spacer()
                if costEstimator.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if totals.hasAnyPrice {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(RecipeCostEstimator.format(totals.full, currencyCode: totals.currencyCode))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    if totals.isPartial {
                        Text("+")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("all ingredients")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                if let summary = readiness, !summary.missing.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cart")
                        Text("About \(RecipeCostEstimator.format(totals.toBuy, currencyCode: totals.currencyCode))\(totals.isPartial ? "+" : "") to buy what you're missing")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                } else if readiness?.canMakeNow == true {
                    Label("Nothing to buy", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                if totals.isPartial {
                    Text("\(totals.pricedCount) of \(totals.priceableCount) ingredients priced so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if costEstimator.isLoading {
                Text("Checking recent receipts and local store prices…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No prices found yet. Scan a receipt or check store stock to build up pricing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INGREDIENTS")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(readiness?.statuses ?? []) { status in
                    ingredientRow(status)
                    if status.id != readiness?.statuses.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func ingredientRow(_ status: RecipeReadiness.IngredientStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon(status))
                .foregroundStyle(statusTint(status))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayLine)
                    .font(.body)
                if let note = statusNote(status) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let line = costEstimator.prices[status.id] {
                Text(RecipeCostEstimator.format(line.price, currencyCode: line.currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.isMissing ? .primary : .secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(_ status: RecipeReadiness.IngredientStatus) -> String {
        switch status.availability {
        case .inFridge: return "checkmark.circle.fill"
        case .staple: return "checkmark.circle"
        case .onShoppingList: return "cart.fill"
        case .missing: return "cart.badge.plus"
        }
    }

    private func statusTint(_ status: RecipeReadiness.IngredientStatus) -> Color {
        switch status.availability {
        case .inFridge, .staple: return .green
        case .onShoppingList: return .blue
        case .missing: return .orange
        }
    }

    private func statusNote(_ status: RecipeReadiness.IngredientStatus) -> String? {
        switch status.availability {
        case .inFridge(let itemName):
            return itemName.lowercased() == status.name.lowercased() ? "In your frydge" : "In your frydge as \(itemName)"
        case .staple: return "Pantry staple"
        case .onShoppingList: return "Already on your shopping list"
        case .missing: return nil
        }
    }

    @ViewBuilder
    private var stepsSection: some View {
        if !stepLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("METHOD")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $stepsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(stepLines.enumerated()), id: \.offset) { index, text in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor.opacity(0.15), in: Circle())
                                Text(text)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("\(stepLines.count) step\(stepLines.count == 1 ? "" : "s") read from the page")
                        .font(.subheadline)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                    }
                    Text(isSaving ? "Saving…" : "Save to My Recipes")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || draft == nil)

            if let summary = readiness, !summary.missing.isEmpty {
                Button {
                    addMissingToShoppingList(summary.missing)
                } label: {
                    Label(
                        addedMissingToList ? "Added to shopping list" : "Add \(summary.missing.count) missing to shopping list",
                        systemImage: addedMissingToList ? "checkmark" : "cart.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(addedMissingToList)
            }

            Button {
                showWizard = true
            } label: {
                Label("Edit details", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 4)
    }

    // MARK: - Pipeline

    @MainActor
    private func process(pages: [UIImage]) async {
        // The blurred backdrop only needs a thumbnail; blurring a 12 MP scan is slow.
        processingImage = pages.first?.snapDownscaled(maxDimension: 600)
        stage = .processing
        saveError = nil
        addedMissingToList = false

        let result = await RecipeSnapReader.read(pages: pages)

        guard let newDraft = await RecipeImportAI.makeDraft(from: result.text) ?? RecipeImportOCRParser.makeDraft(from: result.text) else {
            stage = .failed("Try a closer, flatter shot with the ingredient list and method in view. Good light and a steady hand help.")
            return
        }

        draft = newDraft
        recipeName = newDraft.name
        serves = result.serves ?? "4"
        // Keep the hero at a sensible size: it is rendered at 220 pt and later
        // JPEG-encoded for CloudKit, so a full-resolution page is pure overhead.
        heroImage = result.heroImage?.snapDownscaled(maxDimension: 1600)
        stepLines = RecipeSnapReader.stepTexts(from: newDraft.instructions)
        refreshReadiness()
        if let readiness {
            costEstimator.estimate(readiness.statuses)
        }
        stage = .review
    }

    private func refreshReadiness() {
        guard let draft else { return }
        readiness = RecipeReadiness.evaluate(
            ingredients: draft.ingredients,
            fridgeItems: frydgeManager.storedIngredients,
            shoppingListNames: shoppingListManager.shoppingListItems.map(\.name)
        )
    }

    private func loadPickedPages(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.capture) {
                images.append(image)
            }
        }
        photoItems = []
        guard !images.isEmpty else { return }
        await process(pages: images)
    }

    private func loadPickedHero(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.display) {
            heroImage = image
        }
        heroPickerItem = nil
    }

    /// The draft with the user's inline edits applied (used by the wizard and save).
    private var editedDraft: RecipeImportManager.RecipeImportDraft? {
        guard var d = draft else { return nil }
        let trimmed = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { d.name = trimmed }
        return d
    }

    // MARK: - Actions

    private func addMissingToShoppingList(_ missing: [RecipeReadiness.IngredientStatus]) {
        var added = 0
        for status in missing where !shoppingListManager.isInShoppingList(status.name) {
            shoppingListManager.addToShoppingList(
                name: status.name,
                quantity: status.quantity ?? "1",
                unit: status.unit ?? "",
                location: "Shopping",
                dietaryTags: []
            )
            added += 1
        }
        addedMissingToList = true
        refreshReadiness()
        appState.showBanner(
            title: "Shopping list updated",
            message: "Added \(added) ingredient\(added == 1 ? "" : "s").",
            systemImage: "cart.badge.plus",
            style: .success
        )
    }

    @MainActor
    private func save() async {
        guard let d = editedDraft else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let ingredientLines = d.ingredients
            .map { $0.asAppIngredientLine().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let steps = stepLines
            .map { RecipeStep(text: $0, timerSeconds: RecipeImportWizardView.parseTimer(from: $0)) }
        let instructionText = steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")

        let now = Date()
        let recipe = CloudRecipe(
            name: d.name,
            serves: serves.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "4" : serves,
            ingredients: ingredientLines,
            pan: "",
            instructions: instructionText,
            steps: steps,
            image: heroImage,
            location: "Fridge",
            creationDate: now,
            modificationDate: now
        )

        do {
            let saved = try await RecipeCloudSaver.save(recipe)
            finish(saved)
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func finish(_ saved: CloudRecipe) {
        RecipeListModel.cacheSavedRecipe(saved)
        NotificationCenter.default.post(name: .recipeDidSave, object: saved)
        appState.showBanner(
            title: "Recipe saved",
            message: "\(saved.name) is in your recipes.",
            systemImage: "checkmark.circle.fill",
            style: .success
        )
        onSaved?(saved)
        dismiss()
    }
}

// MARK: - Document camera

/// Embeds the VisionKit document camera and hands back every captured page.
private struct RecipeSnapDocumentCamera: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

// MARK: - OCR + layout

/// Reads recipe pages with Vision, restores column reading order (cookbooks
/// usually put ingredients in one column and the method in another), pulls the
/// dish photo out of the page, and spots a "Serves N" line.
enum RecipeSnapReader {

    struct PageScan {
        let image: UIImage
        let text: String
        /// Normalised Vision bounding boxes (origin bottom-left).
        let textBoxes: [CGRect]
    }

    struct Result {
        let text: String
        let heroImage: UIImage?
        let serves: String?
    }

    static func read(pages: [UIImage]) async -> Result {
        // OCR every page concurrently (a two-page spread halves the wait), then
        // restore page order so the text still reads front to back.
        let scans: [PageScan] = await withTaskGroup(of: (Int, PageScan).self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask { (index, await scan(page)) }
            }
            var indexed: [(Int, PageScan)] = []
            indexed.reserveCapacity(pages.count)
            for await item in group { indexed.append(item) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let text = scans.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Result(
            text: text,
            heroImage: heroImage(from: scans),
            serves: detectServes(in: text)
        )
    }

    static func scan(_ image: UIImage) async -> PageScan {
        let upright = image.normalized()
        guard let cgImage = upright.cgImage else {
            return PageScan(image: upright, text: "", textBoxes: [])
        }

        let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: (request.results ?? []))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }

        let lines = observations.compactMap { obs -> TextLine? in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, box: obs.boundingBox)
        }

        return PageScan(
            image: upright,
            text: orderedText(lines),
            textBoxes: lines.map(\.box)
        )
    }

    private struct TextLine {
        let text: String
        let box: CGRect
    }

    /// Puts lines back into reading order. Single column: top to bottom. Two
    /// columns: anything spanning the page above the columns, then the left
    /// column, then the right, then spanning lines below.
    private static func orderedText(_ lines: [TextLine]) -> String {
        func topDown(_ xs: [TextLine]) -> [TextLine] { xs.sorted { $0.box.midY > $1.box.midY } }

        let narrow = lines.filter { $0.box.width <= 0.55 }
        guard narrow.count >= 6 else {
            return topDown(lines).map(\.text).joined(separator: "\n")
        }

        // Largest gap between line centres marks a possible column gutter.
        let mids = narrow.map(\.box.midX).sorted()
        var bestGap: CGFloat = 0
        var splitX: CGFloat = 0.5
        for i in 1..<mids.count {
            let gap = mids[i] - mids[i - 1]
            if gap > bestGap {
                bestGap = gap
                splitX = (mids[i] + mids[i - 1]) / 2
            }
        }

        guard bestGap > 0.12 else {
            return topDown(lines).map(\.text).joined(separator: "\n")
        }

        // One pass: each line is a left-column, right-column, or spanning line
        // (wide, or centred on the gutter like a title).
        var left: [TextLine] = []
        var right: [TextLine] = []
        var spanning: [TextLine] = []
        var columnTop: CGFloat = 0
        var columnBottom: CGFloat = 1
        for line in lines {
            let isNarrow = line.box.width <= 0.55
            if isNarrow && line.box.midX < splitX - 0.06 {
                left.append(line)
            } else if isNarrow && line.box.midX > splitX + 0.06 {
                right.append(line)
            } else {
                spanning.append(line)
                continue
            }
            columnTop = max(columnTop, line.box.maxY)
            columnBottom = min(columnBottom, line.box.minY)
        }

        guard left.count >= 3, right.count >= 3 else {
            return topDown(lines).map(\.text).joined(separator: "\n")
        }

        var above: [TextLine] = []
        var between: [TextLine] = []
        var below: [TextLine] = []
        for line in spanning {
            if line.box.midY > columnTop {
                above.append(line)
            } else if line.box.midY < columnBottom {
                below.append(line)
            } else {
                between.append(line)
            }
        }

        let ordered = topDown(above) + topDown(left) + topDown(right) + topDown(between) + topDown(below)
        return ordered.map(\.text).joined(separator: "\n")
    }

    // MARK: Hero photo

    /// Finds the dish photo: a page with almost no text, or the largest
    /// text-free band of a page that isn't just blank paper.
    static func heroImage(from scans: [PageScan]) -> UIImage? {
        if scans.count > 1,
           let photoPage = scans.first(where: { $0.textBoxes.count < 4 }),
           !isMostlyUniform(photoPage.image) {
            return photoPage.image
        }

        var best: (image: UIImage, rect: CGRect, area: CGFloat)? = nil
        for scan in scans where !scan.textBoxes.isEmpty {
            // Ignore a stray page number / running header at the page edge.
            let edgeBoxes = scan.textBoxes.filter { $0.minY < 0.04 || $0.maxY > 0.96 }
            let bodyBoxes = edgeBoxes.count <= 2
                ? scan.textBoxes.filter { !($0.minY < 0.04 || $0.maxY > 0.96) }
                : scan.textBoxes
            guard !bodyBoxes.isEmpty else { continue }

            let union = bodyBoxes.reduce(CGRect.null) { $0.union($1) }
            let candidates = [
                CGRect(x: 0, y: union.maxY, width: 1, height: 1 - union.maxY),   // above the text
                CGRect(x: 0, y: 0, width: 1, height: union.minY),                // below the text
                CGRect(x: 0, y: 0, width: union.minX, height: 1),                // left of the text
                CGRect(x: union.maxX, y: 0, width: 1 - union.maxX, height: 1)    // right of the text
            ]
            for candidate in candidates where candidate.width >= 0.22 && candidate.height >= 0.22 {
                let area = candidate.width * candidate.height
                if area > (best?.area ?? 0) {
                    best = (scan.image, candidate, area)
                }
            }
        }

        guard let best, best.area >= 0.15,
              let cropped = crop(best.image, visionRect: best.rect.insetBy(dx: 0.015, dy: 0.015)),
              !isMostlyUniform(cropped) else {
            return nil
        }
        return cropped
    }

    private static func crop(_ image: UIImage, visionRect rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: rect.minX * width,
            y: (1 - rect.maxY) * height,
            width: rect.width * width,
            height: rect.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width > 40, pixelRect.height > 40, let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    /// True when a region is essentially one flat colour (blank paper), judged
    /// from a tiny downsample so it costs nothing.
    private static func isMostlyUniform(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var luminances: [Double] = []
        luminances.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            luminances.append((0.299 * r + 0.587 * g + 0.114 * b) / 255)
        }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luminances.count)
        return variance.squareRoot() < 0.08
    }

    // MARK: Text helpers

    private static let servesRegex = try? NSRegularExpression(
        pattern: #"\b(?:serves|servings?|makes|feeds|portions?)\s*[:\-]?\s*(\d{1,2})\b"#,
        options: [.caseInsensitive]
    )
    private static let stepNumberRegex = try? NSRegularExpression(pattern: #"^\s*\d+\s*[\.)]\s*"#)

    static func detectServes(in text: String) -> String? {
        guard let servesRegex,
              let match = servesRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]), value > 0 else { return nil }
        return String(value)
    }

    /// Splits the parser's numbered instruction block back into step texts.
    static func stepTexts(from instructions: String) -> [String] {
        instructions
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> String? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                guard let stepNumberRegex else { return line }
                let stripped = stepNumberRegex
                    .stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? line : stripped
            }
    }
}

// MARK: - Image sizing

private extension UIImage {
    /// Returns the image scaled so its longest side is at most `maxDimension`
    /// pixels, or the image itself when it already fits. Uses ImageIO's
    /// thumbnailing path, which decodes at the target size instead of drawing
    /// the full bitmap.
    func snapDownscaled(maxDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension, longest > 0 else { return self }
        let ratio = maxDimension / longest
        let target = CGSize(width: (pixelWidth * ratio).rounded(.down), height: (pixelHeight * ratio).rounded(.down))
        return preparingThumbnail(of: target) ?? self
    }
}

// MARK: - Saving

/// Writes a recipe to the public CloudKit recipe database and returns the
/// server copy. Mirrors the import wizard's record layout so both paths save
/// identical records.
enum RecipeCloudSaver {
    static func save(_ recipe: CloudRecipe) async throws -> CloudRecipe {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let database = container.publicCloudDatabase

        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: recipe.id))
        record["name"] = recipe.name as CKRecordValue
        record["serves"] = recipe.serves as CKRecordValue
        record["ingredients"] = recipe.ingredients as NSArray
        record["pan"] = recipe.pan as CKRecordValue
        record["instructions"] = recipe.instructions as CKRecordValue
        record["location"] = recipe.location as CKRecordValue
        record["dietaryTags"] = recipe.dietaryTags as NSArray

        if let data = try? JSONEncoder().encode(recipe.steps),
           let json = String(data: data, encoding: .utf8) {
            record["stepsJSON"] = json as CKRecordValue
        }

        if let image = recipe.image?.normalized(), let asset = image.toCKAsset() {
            record["image"] = asset
        }

        let saved = try await database.save(record)
        return CloudRecipe(from: saved)
    }
}
