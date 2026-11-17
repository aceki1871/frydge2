//
//  FridgeItemRow.swift
//  FrydgeRecipes
//
//  A single fridge item card, shared by the personal ("Mine") list and the
//  shared frydges so both look and behave identically. The row is closure-driven
//  and has no manager dependency — callers wire the taps/usage/add-to-list actions
//  to whichever store backs the item, and attach `.draggable`/`.swipeActions`
//  themselves (payloads differ per store).
//
//  Every row is the same fixed height: the name is a short food noun on one
//  line ("Mayo", not the full scanned product title), the amount sits beside
//  it, and the dietary tag row always reserves its space.
//

import SwiftUI
import CloudKit

struct FridgeItemRow: View {
    let item: StoredIngredient
    /// Bumped by the owner to force thumbnail re-fetch after a manual image sync.
    var syncToken: Int = 0
    /// Shows the "Add to List" affordance instead of the usage slider (item was recently used up).
    var showAddToList: Bool = false

    var onTapDetail: () -> Void
    var onUsageChange: (Double) -> Void
    var onAddToList: () -> Void

    /// Fixed card height so the list scans as a grid of equal rows.
    static let rowHeight: CGFloat = 84

    var body: some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background(Self.glassMaterial)
            .overlay(alignment: .topTrailing) { daysBadge }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
    }

    private var content: some View {
        let usagePercentage = item.quantityUsed
        let isFullyUsed = usagePercentage >= 100
        let remainingFraction = max(0, min(1, 1 - usagePercentage / 100))

        return HStack(alignment: .center, spacing: 12) {
            // Left: thumbnail — isolated so image loads don't redraw the list.
            // A ring around it shows how much is left once some has been used.
            FridgeItemThumbnailView(itemName: item.name, syncToken: syncToken)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if usagePercentage > 0 && !isFullyUsed {
                        remainingRing(fraction: remainingFraction)
                            .offset(x: 5, y: 5)
                    }
                }

            // Center: short name + amount on one line, tags (or reserved space) below.
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    onTapDetail()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(FridgeDisplayName.short(for: item.name))
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(amountLabel(for: item))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // Always 18 pt tall so rows without tags match rows with them.
                HStack(spacing: 6) {
                    ForEach(item.dietaryTags.sorted().prefix(3), id: \.self) { tag in
                        DietaryBadgeChip(tag: tag, tone: .brand)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: how much is left (+/- adjusts) OR "add to list" once it's gone.
            VStack(alignment: .trailing, spacing: 5) {
                if isFullyUsed && showAddToList {
                    Button {
                        onAddToList()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cart.fill.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Add to List")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(remainingText(usage: usagePercentage))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(remainingColor(fraction: remainingFraction))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 8) {
                        Button {
                            onUsageChange(max(0, usagePercentage - 5))
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 17))
                                .foregroundColor(usagePercentage <= 0 ? .gray.opacity(0.3) : .blue)
                                .frame(width: 26, height: 26)
                        }
                        .disabled(usagePercentage <= 0)
                        .buttonStyle(.plain)
                        .accessibilityLabel("More left")

                        remainingBar(fraction: remainingFraction)
                            .frame(height: 8)

                        Button {
                            onUsageChange(min(100, usagePercentage + 5))
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 17))
                                .foregroundColor(usagePercentage >= 100 ? .gray.opacity(0.3) : .blue)
                                .frame(width: 26, height: 26)
                        }
                        .disabled(usagePercentage >= 100)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Used some")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 128)
        }
    }

    // MARK: - Visual helpers (shared with the old FridgeView implementation)

    static var glassMaterial: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }

    /// Inline amount shown next to the item name, e.g. "× 1" or "× 1 kg".
    private func amountLabel(for item: StoredIngredient) -> String {
        let qtyRaw = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitRaw = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let (qty, unit) = FridgeUnits.display(quantity: qtyRaw.isEmpty ? "1" : qtyRaw, unit: unitRaw)
        if unit.isEmpty || unit.lowercased() == "ea" {
            return "× \(qty)"
        }
        return "× \(qty) \(unit)"
    }

    /// "Full" / "≈ 115 g left" / "⅔ left" / "Used up".
    private func remainingText(usage: Double) -> String {
        if usage <= 0 { return "Full" }
        if usage >= 100 { return "Used up" }
        if let amount = FridgeDisplayName.remainingAmount(quantity: item.quantity, unit: item.unit, quantityUsed: usage) {
            return amount
        }
        return "\(Int((100 - usage).rounded())) % left"
    }

    private var accessibilitySummary: String {
        var parts = [item.name, amountLabel(for: item)]
        parts.append(remainingText(usage: item.quantityUsed))
        if !item.dietaryTags.isEmpty { parts.append(item.dietaryTags.sorted().joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    private var daysBadge: some View {
        let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: item.expirationDate).day ?? 0
        let label = item.isExpired ? "!" : "\(daysLeft)d"
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(expiryColor.opacity(0.85), in: Capsule())
            .padding(6)
    }

    private var expiryColor: Color {
        let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: item.expirationDate).day ?? 0
        if item.isExpired || daysLeft <= 0 { return .red }
        if daysLeft <= 2 { return .orange }
        if daysLeft <= 5 { return .yellow }
        return .green
    }

    /// Green while plenty is left, through yellow and orange, red when nearly gone.
    private func remainingColor(fraction: Double) -> Color {
        if fraction > 0.5 { return .green }
        if fraction > 0.25 { return .yellow }
        if fraction > 0.1 { return .orange }
        return .red
    }

    /// Drains from the trailing edge as the item is used: what's shown is what's left.
    private func remainingBar(fraction: Double) -> some View {
        let clamped = max(0, min(1, fraction))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.14))
            Capsule()
                .fill(remainingColor(fraction: clamped))
                .scaleEffect(x: clamped, anchor: .leading)
        }
        .frame(minWidth: 44)
        .animation(.easeInOut(duration: 0.2), value: clamped)
        .accessibilityLabel("\(Int((clamped * 100).rounded())) percent left")
    }

    /// Small ring on the thumbnail: the arc is what's left.
    private func remainingRing(fraction: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color(.systemBackground))
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(remainingColor(fraction: fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared CKRecord → StoredIngredient adapter

extension StoredIngredient {
    /// Builds a display `StoredIngredient` from a shared-frydge `StoredIngredient`
    /// CKRecord so shared items can render through the same `FridgeItemRow` and
    /// `IngredientDetailSheet` as personal items. Shared item records are created
    /// with a UUID record name (see `SharedFridgeManager.importItemsIntoSharedFrydge`),
    /// so `id` parses cleanly; a deterministic fallback keeps identity stable if not.
    init(fromSharedRecord rec: CKRecord) {
        let recordName = rec.recordID.recordName
        let parsedID = UUID(uuidString: recordName)
            ?? UUID(uuidString: String(recordName.prefix(36)))
            ?? DeterministicUUID.from(recordName)

        let qty = (rec["quantity"] as? String)
            ?? (rec["quantity"] as? NSNumber)?.stringValue
            ?? ""

        self.init(
            id: parsedID,
            name: (rec["name"] as? String) ?? "Unnamed",
            quantity: qty,
            unit: (rec["unit"] as? String) ?? "",
            expirationDate: (rec["expirationDate"] as? Date) ?? Date(),
            location: FoodStorageClassifier.normalize((rec["location"] as? String) ?? FoodStorageClassifier.fridge),
            dietaryTags: Set((rec["dietaryTags"] as? [String]) ?? []),
            lifecycle: (rec["lifecycle"] as? String).flatMap(ItemLifecycle.init(rawValue:)) ?? .fridge,
            quantityUsed: (rec["quantityUsed"] as? Double)
                ?? (rec["quantityUsed"] as? NSNumber)?.doubleValue
                ?? 0,
            userPhotoData: []
        )
    }
}

/// Stable UUID from an arbitrary string (used only as a fallback when a shared
/// record name isn't itself a UUID).
private enum DeterministicUUID {
    static func from(_ string: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(string)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((h >> (8 * UInt64(i))) & 0xFF) }
        for i in 8..<16 { bytes[i] = UInt8((h >> (8 * UInt64(i - 8))) & 0xFF) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Per-row thumbnail: owns its own image state so loads don't redraw the whole list

struct FridgeItemThumbnailView: View {
    let itemName: String
    let syncToken: Int

    @ObservedObject private var photoLibrary = UserPhotoLibrary.shared
    @State private var image: UIImage?
    @State private var isLoading = false

    private var cacheKey: String {
        ProductImageCacheManager.shared.imageCacheKey(name: itemName, quantity: "", unit: "")
    }

    var body: some View {
        Group {
            if let img = photoLibrary.firstUIImage(for: itemName) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemGray5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemGray6))
                    Text(FoodEmoji.emoji(for: itemName))
                        .font(.title3)
                }
            }
        }
        .task(id: syncToken) {
            guard photoLibrary.photos(for: itemName).isEmpty else { return }
            if syncToken > 0 { image = nil }
            if let cached = ProductImageCacheManager.shared.uiImage(forKey: cacheKey) {
                image = cached
                return
            }
            isLoading = true
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                isLoading = false
            }
            await ProductImageCacheManager.shared.prefetchIfNeeded(for: itemName)
            timeout.cancel()
            image = ProductImageCacheManager.shared.uiImage(forKey: cacheKey)
            if image == nil {
                // Last resort: a photo another Frydge user contributed for this name.
                image = await CommunityPhotoStore.shared.firstPhoto(barcode: nil, name: itemName)?.image
            }
            isLoading = false
        }
    }
}
