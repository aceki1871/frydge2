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

    // MARK: - Init

    init(recipe: CloudRecipe) {
        recipeName = recipe.name
        steps = recipe.steps
    }

    init(name: String, steps: [RecipeStep]) {
        recipeName = name
        self.steps = steps
    }

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
                    if let guidance = checkGuidance {
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

            if isChecking { checkingOverlay }
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

            // Voice toggle
            Button {
                speech.isEnabled.toggle()
                if !speech.isEnabled { speech.stop() }
            } label: {
                Image(systemName: speech.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.body)
                    .foregroundColor(speech.isEnabled ? .white : Color.white.opacity(0.35))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speech.isEnabled ? "Mute voice" : "Unmute voice")

            // Mic indicator
            if voice.isListening {
                Image(systemName: "mic.fill")
                    .font(.body)
                    .foregroundColor(.green)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.green.opacity(0.12)))
            }

            // Dismiss
            Button {
                handleDisappear()
                dismiss()
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
                Text(step.text)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

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
            cookButton(icon: "camera.fill", label: "Check") {
                openCamera()
            }
            let isLast = stepIndex == steps.count - 1
            cookButton(
                icon: isLast ? "checkmark" : "chevron.right",
                label: isLast ? "Done" : "Next",
                tint: isLast ? .green : .white
            ) {
                if isLast { handleDisappear(); dismiss() } else { goNext() }
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
        setupAudioSession()
        if !steps.isEmpty { enterStep(0) }
        Task {
            await voice.requestAuthorization()
            voice.start()
        }
    }

    private func handleDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        timerTask?.cancel()
        timerTask = nil
        speech.stop()
        voice.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[CookMode] Audio session deactivation: \(error.localizedDescription)")
        }
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
        stopTimer()
        checkGuidance = nil
        stepIndex = index
        let step = steps[index]
        speech.speak(step.text)
        if step.hasTimer, let secs = step.timerSeconds {
            startTimer(secs)
        }
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
        case .check:   openCamera()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
