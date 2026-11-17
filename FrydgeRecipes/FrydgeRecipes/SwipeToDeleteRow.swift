//
//  SwipeToDeleteRow.swift
//  FrydgeRecipes
//
//  Shared swipe-to-delete row wrapper used across Fridge, Shopping List,
//  Shared Shopping List, and anywhere else a list needs swipe-to-delete.
//
//  Interaction model — kept deliberately distinct so a tap never feels like a
//  swipe and vice-versa:
//    • Tap (row closed)        → passes straight through to the row's content.
//    • Horizontal swipe        → reveals the delete action; snaps open.
//    • Swipe past commit point → releasing deletes immediately.
//    • Tap (row open/swiped)   → an invisible catcher closes the row instead of
//                                hitting the content underneath.
//

import SwiftUI

struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var isOpen: Bool = false
    @State private var axis: GestureAxis = .undecided
    @State private var deleteTick: Int = 0

    private enum GestureAxis { case undecided, horizontal, vertical }

    private let actionWidth: CGFloat = 88
    private let openThreshold: CGFloat = 35
    private let deleteThreshold: CGFloat = 120
    private let snap = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86)

    /// How much of the delete action is currently visible (uncapped so the red
    /// always backs the content — no gap appears when rubber-banding).
    private var reveal: CGFloat { max(0, -offsetX) }
    private var isActivated: Bool { isOpen || offsetX != 0 }
    /// Past this point, releasing deletes rather than just opening. Drives the
    /// "armed" visual + haptic so the user can feel the difference.
    private var isArmed: Bool { reveal >= deleteThreshold }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete action background. Deepens in colour and the icon grows
            // once the swipe is "armed", signalling that releasing will delete.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    Rectangle()
                        .fill(isArmed ? Color.red : Color.red.opacity(0.85))
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .scaleEffect(isArmed ? 1.18 : 1.0)
                        .opacity(reveal > 10 ? 1 : 0)
                }
                .frame(width: max(reveal, isActivated ? 0.001 : 0))
                .clipped()
            }
            .cornerRadius(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if reveal > 20 { commitDelete() }
            }

            content()
                .offset(x: offsetX)
                .contentShape(Rectangle())
                .simultaneousGesture(swipeGesture)
                // While the row is swiped open, an invisible catcher takes the
                // tap so it closes the row instead of triggering the content's
                // own buttons. When closed there is no overlay, so taps reach
                // the content immediately with no delay.
                .overlay {
                    if isActivated {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeRow() }
                    }
                }
        }
        .animation(snap, value: isArmed)
        .sensoryFeedback(.selection, trigger: isOpen)
        .sensoryFeedback(trigger: isArmed) { _, armed in
            armed ? .impact(weight: .medium, intensity: 0.7) : nil
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteTick)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                let h = value.translation.width
                let v = value.translation.height

                if axis == .undecided {
                    let absH = abs(h), absV = abs(v)
                    guard max(absH, absV) > 6 else { return }
                    if absH > absV * 1.4 {
                        axis = .horizontal
                        // Absorb the distance already travelled so the row
                        // continues from where it was — no jump when the
                        // gesture "kicks in". offsetX = startOffset + h
                        // should equal the current resting position.
                        startOffset = (isOpen ? -actionWidth : 0) - h
                    } else {
                        axis = .vertical
                    }
                }

                guard axis == .horizontal else { return }

                let candidate = startOffset + h
                if candidate < -deleteThreshold {
                    let excess = candidate + deleteThreshold
                    offsetX = -deleteThreshold + (excess * 0.3)
                } else {
                    offsetX = min(0, candidate)
                }
            }
            .onEnded { value in
                let direction = axis
                axis = .undecided

                guard direction == .horizontal else {
                    if isOpen || offsetX != 0 {
                        withAnimation(snap) {
                            offsetX = isOpen ? -actionWidth : 0
                        }
                    }
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let shouldDelete = offsetX <= -deleteThreshold ||
                                   (offsetX <= -openThreshold && velocity < -150)
                let shouldOpen   = offsetX <= -openThreshold ||
                                   (offsetX <= -20 && velocity < -250)

                if shouldDelete {
                    commitDelete()
                } else if shouldOpen {
                    withAnimation(snap) {
                        offsetX = -actionWidth
                        isOpen = true
                    }
                } else {
                    closeRow()
                }
            }
    }

    private func closeRow() {
        withAnimation(snap) {
            offsetX = 0
            isOpen = false
        }
    }

    private func commitDelete() {
        deleteTick &+= 1
        withAnimation(.easeOut(duration: 0.22)) {
            offsetX = -2000
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            onDelete()
        }
    }
}
