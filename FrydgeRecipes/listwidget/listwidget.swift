//
//  listwidget.swift
//  listwidget
//
//  Shopping list widget for the Home Screen, StandBy and Lock Screen.
//
//  Every family shows the nearest store's logo and name, and each item with
//  its quantity and best known price. Home Screen sizes are interactive:
//  tick an item off, step its quantity, tap a row for its detail sheet, or
//  jump straight into the barcode scanner / add sheet / basket. The main app
//  drains ticks and quantity changes from the shared snapshot on foreground.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Provider

struct FrydgeListProvider: TimelineProvider {
    func placeholder(in context: Context) -> FrydgeListEntry {
        FrydgeListEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FrydgeListEntry) -> Void) {
        let live = WidgetSnapshot.read()
        // The widget gallery should never show an empty list.
        let snapshot = (context.isPreview && live.items.isEmpty) ? WidgetSnapshot.placeholder : live
        completion(FrydgeListEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FrydgeListEntry>) -> Void) {
        let entry = FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.read())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct FrydgeListEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

extension WidgetSnapshot {
    static var placeholder: WidgetSnapshot {
        let sample: [(String, String, Double, String, Double?, String?)] = [
            ("Milk 2L", "🥛", 3.99, "Pak'nSave", 1, ""),
            ("Free range eggs", "🥚", 8.49, "Pak'nSave", 1, "dozen"),
            ("Bananas", "🍌", 2.79, "Countdown", 1, "kg"),
            ("Sourdough loaf", "🍞", 5.50, "Pak'nSave", 1, "loaf"),
            ("Chicken thighs", "🍗", 11.99, "Pak'nSave", 500, "g"),
            ("Greek yoghurt", "🥣", 6.20, "New World", 2, ""),
            ("Spinach", "🥬", 3.49, "Pak'nSave", 1, "bag"),
            ("Olive oil", "🫒", 12.99, "Pak'nSave", 1, "bottle"),
        ]
        return WidgetSnapshot(
            nearestStoreName: "Pak'nSave Sylvia Park",
            nearestStoreDistanceText: "800 m",
            items: sample.enumerated().map { index, row in
                WidgetSnapshotItem(
                    id: "placeholder-\(index)",
                    name: row.0,
                    displayQuantity: nil,
                    priceText: WidgetFormat.money(row.2, currencyCode: "NZD"),
                    priceStoreName: row.3,
                    priceValue: row.2,
                    currencyCode: "NZD",
                    quantityValue: row.4,
                    unit: row.5,
                    emoji: row.1
                )
            },
            tickedItemIDs: [],
            updatedAt: Date()
        )
    }
}

// MARK: - Widget

struct FrydgeListWidget: Widget {
    let kind: String = "FrydgeListWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FrydgeListProvider()) { entry in
            FrydgeListEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    FrydgeWidgetBackground(storeName: entry.snapshot.nearestStoreName)
                }
        }
        .configurationDisplayName("Shopping List")
        .description("Your list with prices at the nearest store. Tick items off, change quantities and scan barcodes without opening the app.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

/// Subtle brand-tinted wash behind Home Screen widgets.
struct FrydgeWidgetBackground: View {
    let storeName: String?

    var body: some View {
        let brand = StoreBrand.resolve(storeName)
        ZStack {
            Rectangle().fill(.fill.tertiary)
            LinearGradient(
                colors: [brand.tint.opacity(brand.assetName == nil ? 0.0 : 0.22), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Entry View Router

struct FrydgeListEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FrydgeListEntry

    var body: some View {
        switch family {
        case .systemSmall:
            FrydgeSmallListView(snapshot: entry.snapshot)
        case .systemMedium:
            FrydgeHomeListView(snapshot: entry.snapshot, capacity: 2, showsActionBar: false)
        case .systemLarge:
            FrydgeHomeListView(snapshot: entry.snapshot, capacity: 5, showsActionBar: true)
        case .accessoryRectangular:
            FrydgeLockRectangularView(snapshot: entry.snapshot)
        case .accessoryCircular:
            FrydgeLockCircularView(snapshot: entry.snapshot)
        case .accessoryInline:
            FrydgeLockInlineView(snapshot: entry.snapshot)
        default:
            FrydgeHomeListView(snapshot: entry.snapshot, capacity: 7, showsActionBar: true)
        }
    }
}

// MARK: - Shared pieces

private extension WidgetSnapshot {
    /// Store to headline: the nearest one, else whichever store priced the list.
    var headlineStoreName: String? {
        if let nearest = nearestStoreName, !nearest.isEmpty { return nearest }
        return items.first(where: { ($0.priceStoreName?.isEmpty == false) })?.priceStoreName
    }

    var totalText: String? {
        guard let total = estimatedTotal else { return nil }
        return WidgetFormat.money(total.value, currencyCode: total.currencyCode)
    }

    /// "3 of 8 priced" style hint when some items still have no price.
    var unpricedCount: Int {
        remainingItems.filter { $0.unitPriceValue == nil }.count
    }
}

/// Round icon button used for scan / add / basket shortcuts.
private struct FrydgeIconButtonLabel: View {
    let systemImage: String
    var size: CGFloat = 30
    var tint: Color = .primary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.10)))
            .contentShape(Circle())
    }
}

/// Header: store logo + name + distance, running total, scan shortcut.
private struct FrydgeStoreHeader: View {
    let snapshot: WidgetSnapshot
    let showsScanLink: Bool

    private var brand: StoreBrand { StoreBrand.resolve(snapshot.headlineStoreName) }

    var body: some View {
        HStack(spacing: 8) {
            StoreLogoView(storeName: snapshot.headlineStoreName, size: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(brand.displayName)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let branch = StoreBrand.branch(from: snapshot.headlineStoreName) {
                        Text(branch).lineLimit(1)
                    }
                    if let distance = snapshot.nearestStoreDistanceText, !distance.isEmpty {
                        if StoreBrand.branch(from: snapshot.headlineStoreName) != nil {
                            Text("·")
                        }
                        Label(distance, systemImage: "location.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 0) {
                if let total = snapshot.totalText {
                    Text(total)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .invalidatableContent()
                } else {
                    Text("No prices yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(itemCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .invalidatableContent()
            }
            .lineLimit(1)

            if showsScanLink {
                Link(destination: WidgetDeepLink.scan) {
                    FrydgeIconButtonLabel(systemImage: "barcode.viewfinder", size: 32)
                }
                .accessibilityLabel("Scan barcode")
            }
        }
    }

    private var itemCountText: String {
        let remaining = snapshot.remainingItems.count
        let unpriced = snapshot.unpricedCount
        if remaining == 0 { return "All done" }
        if unpriced > 0, unpriced < remaining {
            return "\(remaining) items · \(unpriced) unpriced"
        }
        return remaining == 1 ? "1 item" : "\(remaining) items"
    }
}

/// One interactive shopping row: tick, name + price (opens detail), quantity stepper.
private struct FrydgeItemRow: View {
    let item: WidgetSnapshotItem
    let snapshot: WidgetSnapshot
    var compact: Bool = false

    private var ticked: Bool { snapshot.tickedItemIDs.contains(item.id) }
    private var quantity: Double { snapshot.effectiveQuantity(for: item) ?? 1 }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Button(intent: FrydgeWidgetTickItemIntent(itemID: item.id)) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(ticked ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .invalidatableContent()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ticked ? "Un-tick \(item.name)" : "Tick off \(item.name)")

            Link(destination: WidgetDeepLink.item(item, storeName: snapshot.headlineStoreName)) {
                HStack(spacing: 5) {
                    if let emoji = item.emoji, !emoji.isEmpty {
                        Text(emoji)
                            .font(compact ? .caption : .footnote)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .strikethrough(ticked, color: .secondary)
                            .foregroundStyle(ticked ? Color.secondary : Color.primary)

                        if let price = WidgetFormat.priceLine(for: item, headlineStore: snapshot.headlineStoreName) {
                            Text(price)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ticked ? Color.secondary : Color.green)
                                .lineLimit(1)
                        } else {
                            Text("Checking price…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }

            quantityControl
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(ticked ? 0.04 : 0.08))
        )
    }

    @ViewBuilder
    private var quantityControl: some View {
        if item.isCountLike && !ticked {
            HStack(spacing: 0) {
                Button(intent: FrydgeWidgetAdjustQuantityIntent(itemID: item.id, delta: -1)) {
                    Image(systemName: "minus")
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(quantity <= 1)
                .foregroundStyle(quantity <= 1 ? Color.secondary.opacity(0.4) : Color.primary)
                .accessibilityLabel("One fewer \(item.name)")

                Text(WidgetFormat.quantity(for: item, in: snapshot) ?? "×1")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 24)
                    .invalidatableContent()

                Button(intent: FrydgeWidgetAdjustQuantityIntent(itemID: item.id, delta: 1)) {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("One more \(item.name)")
            }
            .background(Capsule().fill(Color.primary.opacity(0.10)))
        } else if let qty = WidgetFormat.quantity(for: item, in: snapshot) {
            Text(qty)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }
}

/// Bottom row of shortcuts for the large widget.
private struct FrydgeActionBar: View {
    var body: some View {
        HStack(spacing: 6) {
            actionLink(WidgetDeepLink.scan, "Scan", "barcode.viewfinder")
            actionLink(WidgetDeepLink.addProduct, "Add", "plus")
            actionLink(WidgetDeepLink.basket, "Basket", "basket.fill")
            actionLink(WidgetDeepLink.shoppingList, "List", "checklist")
        }
    }

    private func actionLink(_ url: URL, _ title: String, _ systemImage: String) -> some View {
        Link(destination: url) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
    }
}

/// Empty-list state with the two most useful next actions.
private struct FrydgeEmptyListView: View {
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: "cart")
                .font(compact ? .title3 : .title)
                .foregroundStyle(.secondary)
            Text("Shopping list is empty")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !compact {
                HStack(spacing: 8) {
                    Link(destination: WidgetDeepLink.scan) {
                        Label("Scan", systemImage: "barcode.viewfinder")
                    }
                    Link(destination: WidgetDeepLink.addProduct) {
                        Label("Add", systemImage: "plus")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home Screen: medium & large

private struct FrydgeHomeListView: View {
    let snapshot: WidgetSnapshot
    let capacity: Int
    let showsActionBar: Bool

    /// Unticked first so a tick doesn't leave a hole at the top; ticked items
    /// stay visible (struck through) until the app drains them.
    private var orderedItems: [WidgetSnapshotItem] {
        let remaining = snapshot.remainingItems
        let ticked = snapshot.items.filter { snapshot.tickedItemIDs.contains($0.id) }
        return remaining + ticked
    }

    private var visibleItems: [WidgetSnapshotItem] { Array(orderedItems.prefix(capacity)) }
    private var overflow: Int { max(0, orderedItems.count - capacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FrydgeStoreHeader(snapshot: snapshot, showsScanLink: true)

            if snapshot.items.isEmpty {
                FrydgeEmptyListView()
            } else {
                VStack(spacing: 4) {
                    ForEach(visibleItems) { item in
                        FrydgeItemRow(item: item, snapshot: snapshot, compact: true)
                    }
                }

                // Medium has no vertical room for this row; its header's
                // item count already says how many more there are.
                if showsActionBar, overflow > 0 || !snapshot.tickedItemIDs.isEmpty {
                    HStack {
                        if overflow > 0 {
                            Link(destination: WidgetDeepLink.shoppingList) {
                                Text("+\(overflow) more")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !snapshot.tickedItemIDs.isEmpty {
                            Button(intent: FrydgeWidgetUntickAllIntent()) {
                                Label("Undo ticks", systemImage: "arrow.uturn.backward")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 0)

                if showsActionBar {
                    FrydgeActionBar()
                }
            }
        }
    }
}

// MARK: - Home Screen: small

private struct FrydgeSmallListView: View {
    let snapshot: WidgetSnapshot

    private var brand: StoreBrand { StoreBrand.resolve(snapshot.headlineStoreName) }
    private var visibleItems: [WidgetSnapshotItem] { Array(snapshot.remainingItems.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StoreLogoView(storeName: snapshot.headlineStoreName, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(brand.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let distance = snapshot.nearestStoreDistanceText, !distance.isEmpty {
                        Text(distance)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 2)
                // `Link` isn't available in the small family, so the scanner
                // opens through a foreground intent instead.
                Button(intent: FrydgeOpenScannerIntent()) {
                    FrydgeIconButtonLabel(systemImage: "barcode.viewfinder", size: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan barcode")
            }

            if snapshot.items.isEmpty {
                FrydgeEmptyListView(compact: true)
            } else {
                VStack(spacing: 3) {
                    ForEach(visibleItems) { item in
                        smallRow(item)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(countText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .invalidatableContent()
                    Spacer()
                    if let total = snapshot.totalText {
                        Text(total)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .invalidatableContent()
                    }
                }
                .lineLimit(1)
            }
        }
        .widgetURL(WidgetDeepLink.shoppingList)
    }

    private func smallRow(_ item: WidgetSnapshotItem) -> some View {
        HStack(spacing: 5) {
            Button(intent: FrydgeWidgetTickItemIntent(itemID: item.id)) {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tick off \(item.name)")

            if let emoji = item.emoji, !emoji.isEmpty {
                Text(emoji).font(.caption2)
            }
            Text(item.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
            if let qty = WidgetFormat.quantity(for: item, in: snapshot), item.isCountLike, (snapshot.effectiveQuantity(for: item) ?? 1) > 1 {
                Text(qty)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let price = item.priceText, !price.isEmpty {
                Text(price)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
    }

    private var countText: String {
        let remaining = snapshot.remainingItems.count
        if remaining == 0 { return "All done" }
        let shown = visibleItems.count
        return remaining > shown ? "+\(remaining - shown) more" : (remaining == 1 ? "1 item" : "\(remaining) items")
    }
}

// MARK: - Lock Screen: rectangular

private struct FrydgeLockRectangularView: View {
    let snapshot: WidgetSnapshot

    private var brand: StoreBrand { StoreBrand.resolve(snapshot.headlineStoreName) }
    private var visibleItems: [WidgetSnapshotItem] { Array(snapshot.remainingItems.prefix(2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "storefront.fill")
                    .font(.caption2)
                Text(brand.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                if let distance = snapshot.nearestStoreDistanceText, !distance.isEmpty {
                    Text("· \(distance)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let total = snapshot.totalText {
                    Text(total)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                }
            }
            .widgetAccentable()

            if visibleItems.isEmpty {
                Text(snapshot.items.isEmpty ? "List is empty · tap to add" : "All ticked off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleItems) { item in
                    HStack(spacing: 4) {
                        Text(item.emoji ?? "•")
                            .font(.caption2)
                        Text(item.name)
                            .font(.caption2)
                            .lineLimit(1)
                        if let qty = WidgetFormat.quantity(for: item, in: snapshot), item.isCountLike, (snapshot.effectiveQuantity(for: item) ?? 1) > 1 {
                            Text(qty)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        if let price = item.priceText, !price.isEmpty {
                            Text(price)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                }
                let more = snapshot.remainingItems.count - visibleItems.count
                if more > 0 {
                    Text("+\(more) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .widgetURL(snapshot.items.isEmpty ? WidgetDeepLink.addProduct : WidgetDeepLink.shoppingList)
    }
}

// MARK: - Lock Screen: circular

private struct FrydgeLockCircularView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let total = snapshot.items.count
        let remaining = snapshot.remainingItems.count
        ZStack {
            AccessoryWidgetBackground()
            if total == 0 {
                Image(systemName: "barcode.viewfinder")
                    .font(.title3.weight(.semibold))
            } else {
                Gauge(value: Double(total - remaining), in: 0...Double(max(total, 1))) {
                    Image(systemName: "cart.fill")
                } currentValueLabel: {
                    Text("\(remaining)")
                        .font(.headline.weight(.bold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        }
        .widgetAccentable()
        // Empty list: the quickest useful action is scanning something.
        .widgetURL(total == 0 ? WidgetDeepLink.scan : WidgetDeepLink.shoppingList)
    }
}

// MARK: - Lock Screen: inline

private struct FrydgeLockInlineView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let brand = StoreBrand.resolve(snapshot.headlineStoreName)
        let remaining = snapshot.remainingItems.count
        var parts: [String] = []
        if remaining == 0 {
            parts.append(snapshot.items.isEmpty ? "List empty" : "All ticked off")
        } else {
            parts.append(remaining == 1 ? "1 item" : "\(remaining) items")
        }
        if let total = snapshot.totalText { parts.append(total) }
        if brand.assetName != nil {
            if let distance = snapshot.nearestStoreDistanceText, !distance.isEmpty {
                parts.append("\(brand.displayName) \(distance)")
            } else {
                parts.append(brand.displayName)
            }
        }
        return HStack(spacing: 4) {
            Image(systemName: "cart.fill")
            Text(parts.joined(separator: " · "))
        }
        .widgetURL(WidgetDeepLink.shoppingList)
    }
}

// MARK: - Previews

#Preview("Home Large", as: .systemLarge) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Home Medium", as: .systemMedium) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Home Small", as: .systemSmall) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Lock Rect", as: .accessoryRectangular) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Lock Circular", as: .accessoryCircular) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}

#Preview("Lock Inline", as: .accessoryInline) {
    FrydgeListWidget()
} timeline: {
    FrydgeListEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
}
