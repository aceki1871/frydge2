//
//  RecipeImportView.swift
//  FrydgeRecipes
//
//  Created by Josh on 10/01/2026.
//
//  The one import window. A single box takes a link *or* pasted recipe text
//  and one Import button works out which it is; Paste & Import does the same
//  straight from the clipboard. Snapping a page is the only other way in.
//  Links and videos shared from other apps appear in a section that only
//  shows when there is something waiting. Once a draft is ready the wizard
//  takes over.
//
//  Also used by the weekly planner via `onImported`, so there is one import
//  screen everywhere rather than a separate link-only sheet.
//

import SwiftUI
import Foundation
import UIKit

struct RecipeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @StateObject private var manager = RecipeImportManager()
    @StateObject private var transcriber = VideoRecipeTranscriber()

    let title: String
    /// If present, the view starts importing this link on appear (share
    /// extension → deep link).
    let incomingURL: URL?
    /// When set, the saved recipe is handed back to the caller instead of
    /// switching to the Recipes tab. The recipe is still saved to the library.
    let onImported: ((CloudRecipe) -> Void)?

    init(title: String = "Import Recipe", incomingURL: URL? = nil, onImported: ((CloudRecipe) -> Void)? = nil) {
        self.title = title
        self.incomingURL = incomingURL
        self.onImported = onImported
    }

    // Input
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    /// Capability check only (`hasStrings` / `hasURLs`), so the system paste
    /// prompt never appears until the user actually taps Paste & Import.
    @State private var clipboardHasContent = false
    /// Error from the text path; the manager owns link errors. Shown in the
    /// same place so the user only ever looks in one spot.
    @State private var textError: String?
    @State private var isParsingText = false

    // Wizard & snap
    @State private var goToWizard = false
    @State private var showingSnap = false

    // Shared with Frydge
    @State private var inboxItems: [RecipeImportInboxItem] = []
    @State private var pendingVideoURL: URL? = nil

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { manager.isLoading || isParsingText }
    private var errorMessage: String? {
        if let textError, !textError.isEmpty { return textError }
        if let e = manager.errorMessage, !e.isEmpty { return e }
        return nil
    }
    private var hasSharedContent: Bool { pendingVideoURL != nil || !inboxItems.isEmpty }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputCard
                    snapButton
                    if hasSharedContent { sharedSection }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(onImported == nil ? "Close" : "Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { inputFocused = false }
                }
            }
            .fullScreenCover(isPresented: $showingSnap) {
                // RecipeSnapView caches, notifies and shows its own banner;
                // we only route the result and close.
                RecipeSnapView { saved in
                    if let onImported { onImported(saved) } else { appState.selectedTab = .recipes }
                    dismiss()
                }
            }
            .fullScreenCover(isPresented: $goToWizard) {
                if let draft = manager.draft {
                    RecipeImportWizardView(
                        draft: draft,
                        prefetchedImage: manager.prefetchedImage
                    ) { saved in
                        RecipeListModel.cacheSavedRecipe(saved)
                        NotificationCenter.default.post(name: .recipeDidSave, object: saved)
                        finish(saved)
                    }
                }
            }
            .onAppear {
                refreshShared()
                checkClipboard()
                if let incomingURL {
                    startImport(from: incomingURL)
                } else if inboxItems.isEmpty && pendingVideoURL == nil {
                    inputFocused = true
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Instagram/Safari: pick up anything newly
                // shared or copied without a manual refresh.
                if phase == .active {
                    refreshShared()
                    checkClipboard()
                }
            }
            .onChange(of: incomingURL) { _, newValue in
                guard let url = newValue else { return }
                startImport(from: url)
            }
            .onChange(of: transcriber.state) { _, state in
                if case .done(let transcript) = state { handleVideoTranscript(transcript) }
            }
            .onChange(of: manager.draft) { _, newDraft in
                if newDraft != nil { goToWizard = true }
            }
        }
    }

    // MARK: - Input card (link or text)

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a link or a recipe")
                .font(.headline)

            TextField("Recipe link, or ingredients and method…", text: $input, axis: .vertical)
                .lineLimit(1...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($inputFocused)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isBusy)

            Text("Works with recipe sites, Instagram and TikTok links, or text copied from anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: importInput) {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isBusy ? loadingLabel : "Import")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedInput.isEmpty || isBusy)

                if trimmedInput.isEmpty {
                    if clipboardHasContent {
                        Button(action: pasteAndImport) {
                            Label("Paste & Import", systemImage: "doc.on.clipboard")
                                .lineLimit(1)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }
                } else {
                    Button {
                        input = ""
                        textError = nil
                        manager.clear()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityLabel("Clear")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: trimmedInput.isEmpty)
    }

    private var loadingLabel: String {
        if isParsingText { return "Reading recipe…" }
        return manager.loadingMessage.isEmpty ? "Fetching…" : manager.loadingMessage
    }

    private func checkClipboard() {
        let board = UIPasteboard.general
        clipboardHasContent = board.hasStrings || board.hasURLs
    }

    /// Reading the pasteboard here is user-initiated, so iOS doesn't show
    /// the "allow paste?" prompt.
    private func pasteAndImport() {
        let board = UIPasteboard.general
        let text = board.string ?? board.url?.absoluteString ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardHasContent = false
            textError = "Nothing to paste. Copy a link or recipe first."
            return
        }
        input = text
        importInput()
    }

    /// One button for both kinds of input: a link is fetched and parsed, and
    /// anything else is read as recipe text. A short message that is mostly a
    /// link (Instagram's "Copy link" sometimes adds a caption) counts as a link.
    private func importInput() {
        inputFocused = false
        textError = nil
        let text = trimmedInput
        guard !text.isEmpty else { return }

        if let url = Self.linkToImport(from: text) {
            startImport(from: url)
            return
        }

        manager.clear()
        isParsingText = true
        Task {
            let draft = await RecipeImportAI.makeDraft(from: text) ?? RecipeImportOCRParser.makeDraft(from: text)
            isParsingText = false
            if let draft {
                manager.draft = draft
            } else {
                textError = "Couldn't find a recipe in that text. Include a title, the ingredients, and the method, then try again."
            }
        }
    }

    /// The URL to fetch if `text` is a link, or a link with only a little
    /// text around it. Longer text containing a link is treated as a recipe.
    static func linkToImport(from text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        guard matches.count == 1, let match = matches.first, let url = match.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let remainder = (text as NSString).replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.count <= 60 ? url : nil
    }

    private func startImport(from url: URL) {
        textError = nil
        manager.clear()
        goToWizard = false
        manager.setURL(url)
        input = url.absoluteString
        Task { await manager.fetchAndParse() }
    }

    // MARK: - Snap

    private var snapButton: some View {
        Button {
            showingSnap = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Snap a recipe page")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Photograph a cookbook or magazine page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: - Shared with Frydge (inbox + video)

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shared with Frydge")
                    .font(.headline)
                Spacer()
                if !inboxItems.isEmpty {
                    Button("Clear") {
                        RecipeImportInbox.clear()
                        refreshShared()
                    }
                    .font(.subheadline)
                }
            }

            VStack(spacing: 8) {
                if pendingVideoURL != nil { videoRow }
                ForEach(inboxItems) { item in inboxRow(item) }
            }
        }
    }

    private func inboxRow(_ item: RecipeImportInboxItem) -> some View {
        Button {
            guard let url = item.url else { return }
            RecipeImportInbox.remove(item)
            refreshShared()
            startImport(from: url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayHost)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(item.urlString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(item.displayDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .contextMenu {
            Button(role: .destructive) {
                RecipeImportInbox.remove(item)
                refreshShared()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var videoRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "video.badge.waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recipe video")
                        .font(.subheadline.weight(.medium))
                    Text(videoStatusText)
                        .font(.caption)
                        .foregroundStyle(videoStatusIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if case .transcribing = transcriber.state { ProgressView() }
            }

            switch transcriber.state {
            case .idle, .failed:
                HStack(spacing: 10) {
                    Button {
                        if let url = pendingVideoURL { transcriber.transcribe(videoURL: url) }
                    } label: {
                        Label(videoStatusIsError ? "Try again" : "Read recipe from audio", systemImage: "waveform.and.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)

                    Button(role: .destructive) {
                        clearVideoQueue()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss video")
                }
            case .transcribing, .done:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var videoStatusText: String {
        switch transcriber.state {
        case .idle:                 return "Shared from another app. We'll listen to the audio and pull out the recipe."
        case .transcribing:         return "Listening to the video…"
        case .done:                 return "Done"
        case .failed(let message):  return message
        }
    }

    private var videoStatusIsError: Bool {
        if case .failed = transcriber.state { return true }
        return false
    }

    private func refreshShared() {
        inboxItems = RecipeImportInbox.items()
        pendingVideoURL = VideoImportQueue.pendingVideoURL()
    }

    private func clearVideoQueue() {
        VideoImportQueue.clear()
        pendingVideoURL = nil
        transcriber.reset()
    }

    private func handleVideoTranscript(_ text: String) {
        clearVideoQueue()
        isParsingText = true
        Task {
            let draft = await RecipeImportAI.makeDraft(from: text) ?? RecipeImportOCRParser.makeDraft(from: text)
            isParsingText = false
            if let draft {
                manager.draft = draft
            } else {
                // Put the transcript where the user can fix it up and retry.
                input = text
                textError = "Couldn't find a recipe in the video's audio. The transcript is above — tidy it up and tap Import."
            }
        }
    }

    // MARK: - Finish

    private func finish(_ saved: CloudRecipe) {
        if let onImported {
            onImported(saved)
        } else {
            appState.selectedTab = .recipes
            appState.showBanner(
                title: "Recipe saved",
                message: "\(saved.name) is in your recipes.",
                systemImage: "checkmark.circle.fill",
                style: .success
            )
        }
        dismiss()
    }
}
