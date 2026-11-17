//
//  DragAutoScroll.swift
//  FrydgeRecipes
//
//  SwiftUI's ScrollView doesn't scroll on its own while a drag-and-drop session
//  hovers near its edge, so dragging an item towards a drop target that's
//  off-screen is a dead end: the page just sits there. This modifier lays two
//  invisible drop zones along the top and bottom edges of the scroll view and,
//  while a drag hovers over one of them, nudges the content in that direction
//  until the finger moves back into the middle.
//
//  Usage:
//      ScrollView { … }
//          .dragAutoScroll(for: DraggableShoppingItem.self, bottomInset: 90)
//

import SwiftUI
import CoreTransferable

struct DragAutoScrollModifier<Payload: Transferable>: ViewModifier {
    let payloadType: Payload.Type

    /// Height of the sensitive strip along each edge.
    var zoneHeight: CGFloat = 72

    /// Space to leave clear at the bottom. The floating tab bar sits over the
    /// bottom of the scroll view and would otherwise cover the bottom zone
    /// (drops don't reach views hidden under a sibling overlay).
    var bottomInset: CGFloat = 0

    /// Points scrolled per tick (~60 ticks/sec).
    private let pointsPerTick: CGFloat = 6

    private struct Snapshot: Equatable {
        var offsetY: CGFloat = 0
        var contentHeight: CGFloat = 0
        var containerHeight: CGFloat = 0
        var insetTop: CGFloat = 0
        var insetBottom: CGFloat = 0
    }

    @State private var position = ScrollPosition()
    @State private var snapshot = Snapshot()
    @State private var scrollTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Snapshot.self) { geo in
                Snapshot(
                    offsetY: geo.contentOffset.y,
                    contentHeight: geo.contentSize.height,
                    containerHeight: geo.containerSize.height,
                    insetTop: geo.contentInsets.top,
                    insetBottom: geo.contentInsets.bottom
                )
            } action: { _, new in
                snapshot = new
            }
            .overlay(alignment: .top) {
                edgeZone(direction: -1)
            }
            .overlay(alignment: .bottom) {
                edgeZone(direction: 1)
                    .padding(.bottom, bottomInset)
            }
            .onDisappear { stopScrolling() }
    }

    /// A transparent strip that only reacts to drag hover. It carries no
    /// gesture, so taps and scroll pans pass straight through to the content.
    ///
    /// IMPORTANT: no `.contentShape(Rectangle())` here. `dropDestination` already
    /// uses this view's own frame as its drop area, and adding an explicit content
    /// shape made this `Color.clear` strip hit-testable for *ordinary taps* too —
    /// swallowing every touch on whatever content happened to sit in the first/last
    /// `zoneHeight` points of the scroll view (e.g. FridgeView's quick-actions row).
    private func edgeZone(direction: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: zoneHeight)
            .dropDestination(for: Payload.self) { _, _ in
                // The zones steer scrolling only; letting go here isn't a drop,
                // so the item animates back to where it came from.
                false
            } isTargeted: { targeted in
                if targeted {
                    startScrolling(direction: direction)
                } else {
                    stopScrolling()
                }
            }
            .accessibilityHidden(true)
    }

    private func startScrolling(direction: CGFloat) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            // Short grace period so a drag that merely *begins* near an edge
            // doesn't lurch before the user has moved anywhere.
            try? await Task.sleep(for: .milliseconds(200))
            while !Task.isCancelled {
                step(direction: direction)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopScrolling() {
        scrollTask?.cancel()
        scrollTask = nil
    }

    @MainActor
    private func step(direction: CGFloat) {
        let s = snapshot
        let minY = -s.insetTop
        let maxY = max(minY, s.contentHeight - s.containerHeight + s.insetBottom)
        let target = min(maxY, max(minY, s.offsetY + direction * pointsPerTick))
        guard abs(target - s.offsetY) > 0.5 else { return }
        position.scrollTo(y: target)
    }
}

extension View {
    /// Auto-scrolls this (vertical) scroll view while a drag of `payloadType`
    /// hovers near its top or bottom edge.
    func dragAutoScroll<Payload: Transferable>(
        for payloadType: Payload.Type,
        zoneHeight: CGFloat = 72,
        bottomInset: CGFloat = 0
    ) -> some View {
        modifier(DragAutoScrollModifier(payloadType: payloadType,
                                        zoneHeight: zoneHeight,
                                        bottomInset: bottomInset))
    }
}
