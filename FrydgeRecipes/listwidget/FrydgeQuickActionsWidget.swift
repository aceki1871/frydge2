//
//  FrydgeQuickActionsWidget.swift
//  listwidget
//
//  One-tap shortcuts into Frydge: barcode scanner, add product, in-store
//  basket and the shopping list. The medium size also shows the nearest
//  store and the running total so it doubles as a glanceable summary.
//

import WidgetKit
import SwiftUI
import AppIntents

struct FrydgeQuickActionsWidget: Widget {
    let kind: String = "FrydgeQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FrydgeListProvider()) { entry in
            FrydgeQuickActionsEntryView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) {
                    FrydgeWidgetBackground(storeName: entry.snapshot.nearestStoreName)
                }
        }
        .configurationDisplayName("Quick Actions")
        .description("Scan a barcode, add a product or open your basket in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

private struct FrydgeQuickActionsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "barcode.viewfinder")
                    .font(.title2.weight(.semibold))
            }
            .widgetAccentable()
            .widgetURL(WidgetDeepLink.scan)
        case .systemSmall:
            FrydgeQuickActionsSmallView(snapshot: snapshot)
        default:
            FrydgeQuickActionsMediumView(snapshot: snapshot)
        }
    }
}

/// Visual spec for one shortcut tile.
private struct QuickAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let url: URL

    static let scan = QuickAction(id: "scan", title: "Scan", systemImage: "barcode.viewfinder", tint: .blue, url: WidgetDeepLink.scan)
    static let add = QuickAction(id: "add", title: "Add", systemImage: "plus", tint: .green, url: WidgetDeepLink.addProduct)
    static let basket = QuickAction(id: "basket", title: "Basket", systemImage: "basket.fill", tint: .orange, url: WidgetDeepLink.basket)
    static let list = QuickAction(id: "list", title: "List", systemImage: "checklist", tint: .purple, url: WidgetDeepLink.shoppingList)

    static let all: [QuickAction] = [.scan, .add, .basket, .list]
}

private struct QuickActionTileLabel: View {
    let action: QuickAction
    var showsTitle: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(action.tint)
            if showsTitle {
                Text(action.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(action.tint.opacity(0.14))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Small: 2×2 grid. `Link` isn't supported in the small family, so each tile
/// is a foreground intent that opens the matching deep link.
private struct FrydgeQuickActionsSmallView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button(intent: FrydgeOpenScannerIntent()) {
                    QuickActionTileLabel(action: .scan)
                }
                Button(intent: FrydgeOpenAddProductIntent()) {
                    QuickActionTileLabel(action: .add)
                }
            }
            HStack(spacing: 6) {
                Button(intent: FrydgeOpenBasketIntent()) {
                    QuickActionTileLabel(action: .basket)
                }
                Button(intent: FrydgeOpenShoppingListIntent()) {
                    QuickActionTileLabel(action: .list)
                }
            }
        }
        .buttonStyle(.plain)
        .widgetURL(WidgetDeepLink.scan)
    }
}

/// Medium: store summary on the left, four shortcut tiles on the right.
private struct FrydgeQuickActionsMediumView: View {
    let snapshot: WidgetSnapshot

    private var brand: StoreBrand { StoreBrand.resolve(snapshot.nearestStoreName) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                StoreLogoView(storeName: snapshot.nearestStoreName, size: 40)
                Text(brand.displayName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if let distance = snapshot.nearestStoreDistanceText, !distance.isEmpty {
                    Label(distance, systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                let remaining = snapshot.remainingItems.count
                Text(remaining == 0 ? "List is empty" : (remaining == 1 ? "1 item to buy" : "\(remaining) items to buy"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let total = snapshot.estimatedTotal {
                    Text(WidgetFormat.money(total.value, currencyCode: total.currencyCode))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Link(destination: QuickAction.scan.url) { QuickActionTileLabel(action: .scan) }
                    Link(destination: QuickAction.add.url) { QuickActionTileLabel(action: .add) }
                }
                GridRow {
                    Link(destination: QuickAction.basket.url) { QuickActionTileLabel(action: .basket) }
                    Link(destination: QuickAction.list.url) { QuickActionTileLabel(action: .list) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .widgetURL(WidgetDeepLink.shoppingList)
    }
}

#Preview("Quick Small", as: .systemSmall) {
    FrydgeQuickActionsWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Quick Medium", as: .systemMedium) {
    FrydgeQuickActionsWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}
