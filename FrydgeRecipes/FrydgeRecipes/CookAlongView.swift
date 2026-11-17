//
//  CookAlongView.swift
//  FrydgeRecipes
//
//  Full-screen hands-free cook mode.
//  - Steps are spoken aloud on entry via SpeechCoach.
//  - Timers auto-start when a step declares timerSeconds.
//  - Voice commands (next / back / repeat / timer / check) are heard via VoiceCommandListener.
//  - "Check my cooking" grabs one camera frame and calls CookCoachService.
//  - Screen stays awake while the view is visible.
//

import SwiftUI
import AVFoundation
import UIKit

struct CookAlongView: View {

    let recipeName: String
    let steps: [RecipeStep]
    /// Which ingredients (with quantities) go in at each step; empty when the
    /// view was given bare steps without the recipe's ingredient list.
    let stagePlan: RecipeStagePlan

    /// Called when the user completes the final step ("Done"). The presenter uses
    /// this to run the fridge-deduction → store-leftovers → back-to-fridge loop.
    /// Abandoning via the X button does not call this.
    var onFinish: () -> Void = {}

    // MARK: - Init

    init(recipe: CloudRecipe, onFinish: @escaping () -> Void = {}) {
        recipeName = recipe.name
        // Legacy recipes carry prose instructions only; infer steps rather
        // than opening cook mode onto "No steps available".
        let resolved = recipe.resolvedSteps
        steps = resolved
        stagePlan = RecipeStagePlan.build(ingredients: recipe.ingredients, steps: resolved)
        self.onFinish = onFinish
    }

    init(name: String, steps: [RecipeStep]) {
        recipeName = name
        self.steps = steps
        stagePlan = RecipeStagePlan.build(ingredients: [], steps: steps)
    }

    // Set to true once CookCoachService has a real backend URL configured.
    private let cookCheckEnabled = false

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechCoach()
    @StateObject private var voice = VoiceCommandListener()

    @State private var stepIndex = 0
    @State private var timerRemaining = 0
    @State private var timerRunning = false
    @State private var timerTask: Task<Void, Never>? = nil

    @State private var isCameraPresented = false
    @State private var isCaptured = false
    @State private var capturedImage: UIImage? = nil
    @State private var isChecking = false
    @State private var checkGuidance: String? = nil

    /// Voice starts OFF. Taking over the audio session and the microphone on
    /// entry stopped the user's music and asked for speech permission mid-task,
    /// so both now wait until the speaker button is tapped.
    @State private var voiceActivated = false

    /// Confirmation before "Finish now", which deducts the whole recipe from
    /// the fridge — people read a bare "Skip" as "skip this step".
    @State private var showFinishConfirm = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if steps.isEmpty {
                emptyView
            } else {
                VStack(spacing: 0) {
                    topBar
                    progressBar.padding(.vertical, 6)
                    stepCard.frame(maxHeight: .infinity)
                    if cookCheckEnabled, let guidance = checkGuidance {
                        guidanceCard(guidance)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    controlBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                }
            }

            if cookCheckEnabled && isChecking { checkingOverlay }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: checkGuidance)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: voice.lastEvent) { _, event in
            guard let event else { return }
            handleVoiceCommand(event.command)
        }
        .onChange(of: capturedImage) { _, img in
            guard let img else { return }
            isCameraPresented = false
            capturedImage = nil
            isCaptured = false
            Task { await runCookCheck(image: img) }
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraCaptureView(isImageCaptured: $isCaptured, capturedImage: $capturedImage)
                .ignoresSafeArea()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(recipeName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            Spacer()

            // Voice toggle — this is also what starts the audio session and the
            // microphone, so nothing is taken over until the user asks for it.
            Button {
                toggleVoice()
            } label: {
                Image(systemName: voiceActivated ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.body)
                    .foregroundColor(voiceActivated ? .white : Color.white.opacity(0.35))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voiceActivated ? "Turn off voice and commands" : "Read steps aloud and listen for commands")

            // Mic indicator
            if voice.isListening {
                Image(systemName: "mic.fill")
                    .font(.body)
                    .foregroundColor(.green)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.green.opacity(0.12)))
            }

            // Ends the cook early and runs the fridge deduction. Confirmed,
            // because it takes ingredients out of the user's fridge.
            Button {
                showFinishConfirm = true
            } label: {
                Text("Finish now")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish cooking and update fridge")
            .confirmationDialog(
                "Finish cooking?",
                isPresented: $showFinishConfirm,
                titleVisibility: .visible
            ) {
                Button("Finish and update fridge") { finishCooking() }
                Button("Keep cooking", role: .cancel) { }
            } message: {
                Text("This takes the recipe's ingredients out of your fridge.")
            }

            // Dismiss
            Button {
                abandonCooking()
            } label: {
                Image(systemName: "xmark")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit cook mode")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(stepIndex + 1) / CGFloat(max(1, steps.count)))
                    .animation(.spring(response: 0.4), value: stepIndex)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 20)
    }

    // MARK: - Step Card

    private var stepCard: some View {
        let step = steps[stepIndex]
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Counter + temperature row
                HStack(spacing: 10) {
                    Text("Step \(stepIndex + 1) of \(steps.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.1)))

                    if let temp = step.temperatureDisplay {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium")
                            Text(temp)
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }

                    Spacer()
                }

                // Step text — large and readable
                Text(step.displayText)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                // Ingredients (with quantities) that go in at this step.
                let stageLines = stagePlan.ingredientLines(forStepID: step.id)
                if !stageLines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Add now", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        StageIngredientChips(lines: stageLines, showsCoverage: false)
                    }
                }

                // Timer
                if timerRunning || timerRemaining > 0 {
                    timerBadge
                }
            }
            .padding(24)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .id(stepIndex)
    }

    // MARK: - Timer Badge

    private var timerBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: timerRunning ? "timer" : "checkmark.circle")
                .font(.title3)
                .foregroundColor(timerRunning ? .yellow : .green)

            Text(formatTime(timerRemaining))
                .font(.title2.monospacedDigit())
                .fontWeight(.bold)
                .foregroundColor(timerRunning ? .yellow : .secondary)

            if timerRunning {
                Text("remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("done")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(timerRunning ? Color.yellow.opacity(0.1) : Color.green.opacity(0.1))
        )
    }

    // MARK: - Guidance Card

    private func guidanceCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundColor(.yellow)
                .padding(.top, 2)

            Text(text)
                .font(.callout)
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button { checkGuidance = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color.white.opacity(0.3))
                    .font(.callout)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.yellow.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Checking Overlay

    private var checkingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text("Checking your cooking…")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            cookButton(icon: "chevron.left", label: "Back", disabled: stepIndex == 0) {
                goBack()
            }
            cookButton(icon: "arrow.counterclockwise", label: "Repeat") {
                repeatCurrent()
            }
            // Chef: how-tos for the hand skills this step assumes (crack an
            // egg, slice the fillet…). Lights up orange when there's a match.
            ChefButton(
                relevant: steps.indices.contains(stepIndex) ? ChefTechniqueLibrary.relevant(to: steps[stepIndex]) : [],
                context: "step \(stepIndex + 1)",
                style: .onDark
            )
            if cookCheckEnabled {
                cookButton(icon: "camera.fill", label: "Check") {
                    openCamera()
                }
            }
            let isLast = stepIndex == steps.count - 1
            cookButton(
                icon: isLast ? "checkmark" : "chevron.right",
                label: isLast ? "Done" : "Next",
                tint: isLast ? .green : .white
            ) {
                if isLast { finishCooking() } else { goNext() }
            }
        }
    }

    @ViewBuilder
    private func cookButton(
        icon: String,
        label: String,
        disabled: Bool = false,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint == .white
                          ? Color.white.opacity(disabled ? 0.05 : 0.12)
                          : tint.opacity(0.22))
            )
            .foregroundColor(disabled ? Color.white.opacity(0.25) : tint)
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No steps available")
                .font(.headline)
                .foregroundColor(.secondary)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        UIApplication.shared.isIdleTimerDisabled = true
        // Deliberately silent: no audio session, no microphone, no permission
        // prompt until the user taps the speaker button. Cook mode used to stop
        // whatever the user was listening to the moment it opened.
        speech.isEnabled = false
        if !steps.isEmpty {
            enterStep(0)
            // Put the recipe on the Lock Screen / Dynamic Island so the cook
            // stays on track with the phone locked — or while nipping out to
            // the shop for a missing ingredient.
            let first = steps[0]
            ActivityManager.beginCooking(
                recipeName: recipeName,
                stepIndex: 0,
                stepCount: steps.count,
                stepText: first.displayText,
                timerSeconds: first.hasTimer ? first.timerSeconds : nil
            )
        }
    }

    private func handleDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        // Hand the Live Activity back to the shopping list (or take it down).
        ActivityManager.endCooking()
        timerTask?.cancel()
        timerTask = nil
        guard voiceActivated else { return }   // never started; nothing to tear down
        voiceActivated = false
        speech.stop()
        voice.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[CookMode] Audio session deactivation: \(error.localizedDescription)")
        }
    }

    /// Turns hands-free mode on or off. The first "on" is what claims the audio
    /// session and asks for speech-recognition permission.
    private func toggleVoice() {
        if voiceActivated {
            voiceActivated = false
            speech.isEnabled = false
            speech.stop()
            voice.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        voiceActivated = true
        speech.isEnabled = true
        setupAudioSession()
        Task {
            await voice.requestAuthorization()
            voice.start()
        }
        // Read the step they're on, so turning it on does something immediately.
        if steps.indices.contains(stepIndex) {
            speech.speak(steps[stepIndex].text)
        }
    }

    /// Completed all steps: hand control to the presenter for the deduction +
    /// leftovers + return-to-fridge loop instead of scheduling a delayed reminder.
    private func finishCooking() {
        handleDisappear()
        dismiss()
        onFinish()
    }

    /// Bailed out early: tear down and fall back to the 1-hour "got leftovers?"
    /// notification — but only if they actually started cooking. Opening the
    /// wrong recipe and closing it shouldn't book a notification.
    private func abandonCooking() {
        let startedCooking = stepIndex > 0
        handleDisappear()
        if startedCooking {
            LeftoverManager.scheduleLeftoverCheck(recipeName: recipeName)
        }
        dismiss()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .defaultToSpeaker]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[CookMode] Audio session setup: \(error.localizedDescription)")
        }
    }

    // MARK: - Step Navigation

    private func enterStep(_ index: Int) {
        // Steps can be regenerated asynchronously mid-cook, so never trust an
        // index computed against an older array.
        guard steps.indices.contains(index) else { return }
        stopTimer()
        checkGuidance = nil
        stepIndex = index
        let step = steps[index]
        speech.speak(step.text)
        if step.hasTimer, let secs = step.timerSeconds {
            startTimer(secs)
        }
        // Mirror the step (and its timer) onto the Live Activity.
        ActivityManager.updateCooking(
            stepIndex: index,
            stepText: step.displayText,
            timerSeconds: step.hasTimer ? step.timerSeconds : nil
        )
    }

    private func goNext() {
        guard stepIndex < steps.count - 1 else { return }
        enterStep(stepIndex + 1)
    }

    private func goBack() {
        guard stepIndex > 0 else { return }
        enterStep(stepIndex - 1)
    }

    private func repeatCurrent() {
        guard steps.indices.contains(stepIndex) else { return }
        speech.stop()
        speech.speak(steps[stepIndex].text)
    }

    // MARK: - Timer

    private func startTimer(_ seconds: Int) {
        timerRemaining = seconds
        timerRunning = true
        timerTask = Task {
            while timerRemaining > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                timerRemaining -= 1
            }
            guard !Task.isCancelled else { return }
            timerRunning = false
            if timerRemaining == 0 {
                speech.speak("Time's up!")
                // Swap the Live Activity's countdown back to elapsed cook time.
                ActivityManager.clearCookingTimer()
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerRunning = false
        timerRemaining = 0
    }

    // MARK: - Camera Check-In

    private func openCamera() {
        capturedImage = nil
        isCaptured = false
        isCameraPresented = true
    }

    private func runCookCheck(image: UIImage) async {
        isChecking = true
        checkGuidance = nil
        do {
            let guidance = try await CookCoachService.checkStep(image: image, stepText: steps[stepIndex].text)
            checkGuidance = guidance
            speech.speak(guidance)
        } catch {
            checkGuidance = "Couldn't reach the cooking assistant. Check your connection."
        }
        isChecking = false
    }

    // MARK: - Voice Commands

    private func handleVoiceCommand(_ command: VoiceCommand) {
        switch command {
        case .next:    goNext()
        case .back:    goBack()
        case .repeat:  repeatCurrent()
        case .timer:
            let msg = timerRunning
                ? "Timer: \(formatTime(timerRemaining)) remaining"
                : "No timer running for this step"
            speech.speak(msg)
        case .check:
            // The Check button is hidden when cookCheckEnabled is false, so the
            // voice route must be gated too — otherwise "check" opens a camera
            // for a feature that isn't wired up.
            if cookCheckEnabled {
                openCamera()
            } else {
                speech.speak("Cooking checks aren't available yet.")
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
