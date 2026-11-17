//
//  StepAnimationView.swift
//  FrydgeRecipes
//
//  Procedural, asset-free step animations. Every CookAction maps to one of
//  12 primitives, so a new verb animates the moment you add it to the enum.
//

import SwiftUI

struct StepAnimationView: View {
    private let primitive: AnimationPrimitive
    private let heat: HeatLevel?
    private let isCold: Bool
    private let temperatureDisplay: String?
    private let accessibilityText: String
    var isPlaying: Bool = true
    var tint: Color = .blue

    /// The usual case: an animation driven by a recipe step's action, heat and
    /// temperature so Cook Mode shows exactly what that step calls for.
    init(step: RecipeStep, isPlaying: Bool = true, tint: Color = .blue) {
        self.primitive = step.action?.primitive ?? .wait
        self.heat = step.heat
        switch step.action {
        case .chill, .freeze, .thaw: self.isCold = true
        default: self.isCold = false
        }
        self.temperatureDisplay = step.temperatureDisplay
        self.accessibilityText = step.shortTitle
        self.isPlaying = isPlaying
        self.tint = tint
    }

    /// A bare motion with no recipe context — used to demonstrate a Chef
    /// Technique, which has no heat, temperature or step text of its own.
    init(primitive: AnimationPrimitive, isPlaying: Bool = true, tint: Color = .blue, accessibilityLabel: String = "") {
        self.primitive = primitive
        self.heat = nil
        self.isCold = false
        self.temperatureDisplay = nil
        self.accessibilityText = accessibilityLabel
        self.isPlaying = isPlaying
        self.tint = tint
    }

    /// Heat makes things move faster. Waiting is slow.
    private var period: Double {
        let base: Double
        switch primitive {
        case .knife:    base = 0.75
        case .stir:     base = 2.0
        case .whisk:    base = 0.45
        case .pour:     base = 1.6
        case .heat:     base = 2.2
        case .bubble:   base = 2.4
        case .oven:     base = 3.0
        case .wait:     base = 4.0
        case .sprinkle: base = 1.8
        case .flip:     base = 2.2
        case .blend:    base = 0.5
        case .plate:    base = 3.0
        }
        let intensity = heat?.intensity ?? 1.0
        return max(0.25, base / intensity)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !isPlaying)) { ctx in
            GeometryReader { geo in
                let p = Self.phase(ctx.date, period: period)
                ZStack {
                    content(p: p, size: geo.size)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func content(p: Double, size: CGSize) -> some View {
        switch primitive {
        case .knife:    KnifeAnim(p: p, size: size, tint: tint)
        case .stir:     StirAnim(p: p, size: size, tint: tint)
        case .whisk:    WhiskAnim(p: p, size: size, tint: tint)
        case .pour:     PourAnim(p: p, size: size, tint: tint)
        case .heat:     HeatAnim(p: p, size: size, tint: heat?.tint ?? .orange)
        case .bubble:   BubbleAnim(p: p, size: size, tint: tint)
        case .oven:     OvenAnim(p: p, size: size, label: temperatureDisplay)
        case .wait:     WaitAnim(p: p, size: size, cold: isCold, tint: isCold ? .cyan : tint)
        case .sprinkle: SprinkleAnim(p: p, size: size, tint: tint)
        case .flip:     FlipAnim(p: p, size: size, tint: heat?.tint ?? .orange)
        case .blend:    BlendAnim(p: p, size: size, tint: tint)
        case .plate:    PlateAnim(p: p, size: size, tint: tint)
        }
    }

    static func phase(_ date: Date, period: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: period) / period
    }
}

// MARK: - Shared bits

private func wave(_ p: Double) -> Double { sin(p * 2 * .pi) }           // -1...1
private func bounce(_ p: Double) -> Double { abs(sin(p * .pi)) }        // 0...1

private struct Board: View {
    let size: CGSize
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.brown.opacity(0.35))
            .frame(width: size.width * 0.7, height: size.height * 0.1)
            .position(x: size.width * 0.5, y: size.height * 0.78)
    }
}

// MARK: - 1. Knife

private struct KnifeAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        let drop = bounce(p)
        ZStack {
            Board(size: size)

            // Pieces separating as the blade falls
            ForEach(0..<4, id: \.self) { i in
                let spread = CGFloat(i - 2) * (6 + 5 * drop)
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.75))
                    .frame(width: size.width * 0.05, height: size.height * 0.075)
                    .position(x: size.width * 0.5 + spread, y: size.height * 0.71)
            }

            // Blade
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: size.width * 0.34, height: size.height * 0.09)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: size.width * 0.13, height: size.height * 0.05)
                    .offset(x: size.width * 0.12)
            }
            .rotationEffect(.degrees(-32 * (1 - drop)), anchor: .bottomTrailing)
            .position(x: size.width * 0.52, y: size.height * 0.55)
        }
    }
}

// MARK: - 2. Stir

private struct StirAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        let r = min(size.width, size.height) * 0.26
        let angle = p * 2 * .pi
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: r * 2.4, height: r * 2.4)
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 3)
                .frame(width: r * 2.4, height: r * 2.4)

            // Swirling contents
            ForEach(0..<5, id: \.self) { i in
                let a = angle + Double(i) * (2 * .pi / 5)
                Circle()
                    .fill(tint.opacity(0.55))
                    .frame(width: r * 0.28, height: r * 0.28)
                    .offset(x: cos(a) * r * 0.55, y: sin(a) * r * 0.55)
            }

            // Spoon
            Capsule()
                .fill(Color.brown.opacity(0.7))
                .frame(width: r * 0.16, height: r * 1.5)
                .offset(y: -r * 0.55)
                .rotationEffect(.degrees(p * 360))
        }
        .position(x: size.width * 0.5, y: size.height * 0.5)
    }
}

// MARK: - 3. Whisk

private struct WhiskAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        let r = min(size.width, size.height) * 0.26
        let sway = wave(p)
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: r * 2.4, height: r * 2.4)
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 3)
                .frame(width: r * 2.4, height: r * 2.4)

            ForEach(0..<4, id: \.self) { i in
                let lift = (p + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(.white.opacity(0.7 * (1 - lift)))
                    .frame(width: r * 0.18, height: r * 0.18)
                    .offset(x: CGFloat(i - 2) * r * 0.3, y: r * 0.4 - CGFloat(lift) * r * 1.1)
            }

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Ellipse()
                        .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 2)
                        .frame(width: r * (0.35 + Double(i) * 0.18), height: r * 0.95)
                }
                Capsule()
                    .fill(Color.secondary.opacity(0.8))
                    .frame(width: r * 0.14, height: r * 0.9)
                    .offset(y: -r * 0.8)
            }
            .offset(y: -r * 0.1)
            .rotationEffect(.degrees(sway * 18))
        }
        .position(x: size.width * 0.5, y: size.height * 0.5)
    }
}

// MARK: - 4. Pour

private struct PourAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        ZStack {
            // Source jug, tilted
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: size.width * 0.2, height: size.height * 0.24)
                .rotationEffect(.degrees(38))
                .position(x: size.width * 0.32, y: size.height * 0.26)

            // Stream
            ForEach(0..<6, id: \.self) { i in
                let t = (p + Double(i) / 6).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(tint.opacity(0.8))
                    .frame(width: size.width * 0.035, height: size.width * 0.035)
                    .position(
                        x: size.width * (0.42 + 0.06 * t),
                        y: size.height * (0.36 + 0.32 * t)
                    )
            }

            // Receiving bowl
            Capsule()
                .fill(tint.opacity(0.15))
                .frame(width: size.width * 0.42, height: size.height * 0.2)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 3))
                .position(x: size.width * 0.52, y: size.height * 0.75)
        }
    }
}

// MARK: - 5. Heat (sauté / fry / sear)

private struct HeatAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        let jiggle = wave(p * 3)
        ZStack {
            // Heat waves
            ForEach(0..<3, id: \.self) { i in
                let t = (p + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Capsule()
                    .fill(tint.opacity(0.35 * (1 - t)))
                    .frame(width: size.width * 0.04, height: size.height * 0.16)
                    .position(
                        x: size.width * (0.4 + Double(i) * 0.1),
                        y: size.height * (0.45 - 0.3 * t)
                    )
            }

            // Pan
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: size.width * 0.5, height: size.height * 0.13)
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: size.width * 0.26, height: size.height * 0.045)
                    .offset(x: size.width * 0.36)
            }
            .position(x: size.width * 0.45, y: size.height * 0.58)

            // Food jiggling in the pan
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: size.width * 0.07, height: size.width * 0.07)
                    .position(
                        x: size.width * (0.34 + Double(i) * 0.11),
                        y: size.height * 0.55 + CGFloat(jiggle) * 3
                    )
            }

            // Flames
            ForEach(0..<4, id: \.self) { i in
                let f = bounce((p + Double(i) * 0.2).truncatingRemainder(dividingBy: 1))
                Capsule()
                    .fill(tint.opacity(0.7))
                    .frame(width: size.width * 0.035, height: size.height * (0.05 + 0.06 * f))
                    .position(x: size.width * (0.32 + Double(i) * 0.09), y: size.height * 0.72)
            }
        }
    }
}

// MARK: - 6. Bubble (boil / simmer / steam)

private struct BubbleAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        ZStack {
            // Steam
            ForEach(0..<3, id: \.self) { i in
                let t = (p + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Capsule()
                    .fill(Color.secondary.opacity(0.28 * (1 - t)))
                    .frame(width: size.width * 0.05, height: size.height * 0.12)
                    .position(x: size.width * (0.4 + Double(i) * 0.1), y: size.height * (0.36 - 0.24 * t))
            }

            // Pot
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: size.width * 0.46, height: size.height * 0.3)
                .position(x: size.width * 0.5, y: size.height * 0.62)

            // Liquid + bubbles, clipped to the pot
            ZStack {
                Rectangle().fill(tint.opacity(0.4))
                ForEach(0..<7, id: \.self) { i in
                    let t = (p + Double(i) / 7).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .fill(.white.opacity(0.8 * (1 - t)))
                        .frame(width: size.width * (0.02 + 0.025 * t))
                        .offset(
                            x: size.width * (0.06 * Double(i % 5) - 0.12),
                            y: size.height * (0.1 - 0.2 * t)
                        )
                }
            }
            .frame(width: size.width * 0.42, height: size.height * 0.22)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .position(x: size.width * 0.5, y: size.height * 0.64)
        }
    }
}

// MARK: - 7. Oven (bake / roast)

private struct OvenAnim: View {
    let p: Double; let size: CGSize
    let label: String?

    var body: some View {
        let glow = 0.4 + 0.35 * bounce(p)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: size.width * 0.58, height: size.height * 0.6)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.orange.opacity(glow), Color.orange.opacity(0.05)],
                        center: .center, startRadius: 2, endRadius: size.width * 0.3
                    )
                )
                .frame(width: size.width * 0.46, height: size.height * 0.38)
                .offset(y: size.height * 0.04)

            // Tray + contents
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.brown.opacity(0.75))
                            .frame(width: size.width * 0.06)
                    }
                }
                Capsule().fill(Color.secondary.opacity(0.6))
                    .frame(width: size.width * 0.34, height: 4)
            }
            .offset(y: size.height * 0.06)

            if let label {
                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .offset(y: -size.height * 0.22)
            }
        }
        .position(x: size.width * 0.5, y: size.height * 0.5)
    }
}

// MARK: - 8. Wait (rest / chill / freeze / marinate)

private struct WaitAnim: View {
    let p: Double; let size: CGSize; let cold: Bool; let tint: Color

    var body: some View {
        let r = min(size.width, size.height) * 0.22
        ZStack {
            if cold {
                Image(systemName: "snowflake")
                    .font(.system(size: r * 1.6, weight: .light))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(p * 360))
                    .opacity(0.6 + 0.4 * bounce(p))
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 4)
                    .frame(width: r * 2, height: r * 2)
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: r * 0.85)
                    .offset(y: -r * 0.42)
                    .rotationEffect(.degrees(p * 360))
                Circle().fill(tint).frame(width: 7, height: 7)
            }
        }
        .position(x: size.width * 0.5, y: size.height * 0.5)
    }
}

// MARK: - 9. Sprinkle (season / garnish)

private struct SprinkleAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: size.width * 0.13, height: size.height * 0.2)
                .rotationEffect(.degrees(30 + 8 * wave(p)))
                .position(x: size.width * 0.42, y: size.height * 0.24)

            ForEach(0..<9, id: \.self) { i in
                let t = (p + Double(i) / 9).truncatingRemainder(dividingBy: 1)
                let drift = Double(i % 3 - 1) * 10
                Circle()
                    .fill(tint.opacity(1 - t))
                    .frame(width: 4, height: 4)
                    .position(
                        x: size.width * 0.48 + CGFloat(drift * t),
                        y: size.height * (0.34 + 0.34 * t)
                    )
            }

            Ellipse()
                .fill(tint.opacity(0.15))
                .overlay(Ellipse().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 3))
                .frame(width: size.width * 0.44, height: size.height * 0.16)
                .position(x: size.width * 0.5, y: size.height * 0.74)
        }
    }
}

// MARK: - 10. Flip

private struct FlipAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        let lift = bounce(p)
        ZStack {
            ZStack(alignment: .trailing) {
                Capsule().fill(Color.secondary.opacity(0.5))
                    .frame(width: size.width * 0.5, height: size.height * 0.12)
                Capsule().fill(Color.secondary.opacity(0.5))
                    .frame(width: size.width * 0.24, height: size.height * 0.04)
                    .offset(x: size.width * 0.35)
            }
            .rotationEffect(.degrees(-6 * lift))
            .position(x: size.width * 0.45, y: size.height * 0.68)

            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: size.width * 0.2, height: size.height * 0.08)
                .rotation3DEffect(.degrees(p * 360), axis: (x: 1, y: 0, z: 0))
                .position(x: size.width * 0.42, y: size.height * 0.62 - CGFloat(lift) * size.height * 0.22)
        }
    }
}

// MARK: - 11. Blend

private struct BlendAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 3)
                )
                .frame(width: size.width * 0.36, height: size.height * 0.6)

            ForEach(0..<3, id: \.self) { i in
                Ellipse()
                    .strokeBorder(tint.opacity(0.6), lineWidth: 3)
                    .frame(width: size.width * (0.1 + Double(i) * 0.08), height: size.height * 0.12)
                    .rotationEffect(.degrees(p * 720 + Double(i) * 40))
                    .offset(y: size.height * (0.1 - Double(i) * 0.09))
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.7))
                .frame(width: size.width * 0.22, height: 3)
                .rotationEffect(.degrees(p * 1080))
                .offset(y: size.height * 0.2)
        }
        .position(x: size.width * 0.5, y: size.height * 0.5)
    }
}

// MARK: - 12. Plate

private struct PlateAnim: View {
    let p: Double; let size: CGSize; let tint: Color

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Ellipse().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 3))
                .frame(width: size.width * 0.6, height: size.height * 0.34)

            ForEach(0..<3, id: \.self) { i in
                let t = min(1, max(0, (p * 3) - Double(i)))
                Circle()
                    .fill(tint.opacity(0.7))
                    .frame(width: size.width * 0.1 * CGFloat(t), height: size.width * 0.1 * CGFloat(t))
                    .offset(x: size.width * (Double(i) - 1) * 0.11, y: -size.height * 0.02)
            }

            Image(systemName: "sparkles")
                .font(.system(size: size.width * 0.09))
                .foregroundStyle(.yellow.opacity(bounce(p)))
                .offset(x: size.width * 0.22, y: -size.height * 0.16)
        }
        .position(x: size.width * 0.5, y: size.height * 0.52)
    }
}
