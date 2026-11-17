import SwiftUI
import VisionKit
import Vision

// MARK: - Parsed item from OCR text

struct ScannedShoppingItem: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String
    var isSelected: Bool = true
}

// MARK: - Shopping List Scan Flow

enum ScanDestination {
    case shopping
    case fridge
}

struct ShoppingListScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @EnvironmentObject var frydgeManager: FrydgeManager

    /// Where confirmed items are added. Defaults to the shopping list so existing
    /// call sites are unchanged; the fridge passes `.fridge`.
    var destination: ScanDestination = .shopping

    @State private var scannedItems: [ScannedShoppingItem] = []
    @State private var isScanning = true
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    ShoppingListDocumentScanner(
                        onComplete: { text in
                            isScanning = false
                            isProcessing = true
                            scannedItems = ShoppingListOCRParser.parse(text)
                            isProcessing = false
                        },
                        onCancel: {
                            dismiss()
                        }
                    )
                    .ignoresSafeArea()
                } else if isProcessing {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Reading your list...")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ShoppingListScanConfirmationView(
                        items: $scannedItems,
                        onConfirm: {
                            addSelectedItems()
                            dismiss()
                        },
                        onRescan: {
                            scannedItems = []
                            isScanning = true
                        }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func addSelectedItems() {
        for item in scannedItems where item.isSelected {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let qty = item.quantity.isEmpty ? "1" : item.quantity

            switch destination {
            case .shopping:
                shoppingListManager.addToShoppingList(name: name, quantity: qty)
            case .fridge:
                frydgeManager.addProduct(
                    name: name,
                    quantity: qty,
                    unit: "",
                    expirationDate: StoredIngredient.defaultExpiry(for: name),
                    location: "Fridge",
                    dietaryTags: [],
                    lifecycle: .fridge
                )
            }
        }
    }
}

// MARK: - Document Scanner Wrapper

private struct ShoppingListDocumentScanner: UIViewControllerRepresentable {
    var onComplete: (String) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (String) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            Task {
                let text = await OCRService.recognize(scan: scan)
                await MainActor.run {
                    onComplete(text)
                }
            }
        }
    }
}

// MARK: - OCR Text Parser

enum ShoppingListOCRParser {
    static func parse(_ text: String) -> [ScannedShoppingItem] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var items: [ScannedShoppingItem] = []
        let seen = NSMutableSet()

        for line in lines {
            let cleaned = cleanLine(line)
            guard !cleaned.isEmpty else { continue }

            // Skip lines that look like headers or non-item text
            if looksLikeHeader(cleaned) { continue }

            let (name, quantity) = extractQuantity(from: cleaned)
            let normalizedKey = name.lowercased()
            guard !normalizedKey.isEmpty, !seen.contains(normalizedKey) else { continue }

            seen.add(normalizedKey)
            items.append(ScannedShoppingItem(name: name, quantity: quantity))
        }

        return items
    }

    private static func cleanLine(_ line: String) -> String {
        var cleaned = line

        // Remove common list prefixes: bullets, dashes, numbers, checkboxes
        let prefixPattern = #"^[\-\•\*•○□☐☑☒\[\]\(\)]+\s*"#
        cleaned = cleaned.replacingOccurrences(of: prefixPattern, with: "", options: .regularExpression)

        // Remove leading number + period/parenthesis (e.g. "1. " or "3) ")
        let numberPrefixPattern = #"^\d+[\.\)]\s*"#
        cleaned = cleaned.replacingOccurrences(of: numberPrefixPattern, with: "", options: .regularExpression)

        // Remove trailing punctuation
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))

        return cleaned
    }

    private static func looksLikeHeader(_ text: String) -> Bool {
        let lower = text.lowercased()
        let headerKeywords = [
            "shopping list", "grocery list", "to buy", "need to get",
            "items needed", "groceries", "shopping", "list"
        ]
        // Only match if the entire line is basically a header
        if headerKeywords.contains(lower) { return true }
        // Very short lines that are all caps are likely headers
        if text.count <= 3 && text == text.uppercased() && text.rangeOfCharacter(from: .letters) != nil { return true }
        return false
    }

    private static func extractQuantity(from text: String) -> (name: String, quantity: String) {
        // Match patterns like "2x Milk", "3 Apples", "1kg Chicken", "500g Mince"
        let quantityPattern = #"^(\d+(?:\.\d+)?)\s*([xX]|kg|g|ml|l|L|oz|lb|lbs|packs?|bottles?|cans?|bags?|boxes?|bunch(?:es)?|dozen|doz)?\s+(.+)$"#
        if let match = text.range(of: quantityPattern, options: .regularExpression) {
            let fullMatch = String(text[match])
            let regex = try? NSRegularExpression(pattern: quantityPattern, options: [])
            if let result = regex?.firstMatch(in: fullMatch, range: NSRange(fullMatch.startIndex..., in: fullMatch)) {
                let number = result.range(at: 1).location != NSNotFound
                    ? String(fullMatch[Range(result.range(at: 1), in: fullMatch)!])
                    : ""
                let unit = result.range(at: 2).location != NSNotFound
                    ? String(fullMatch[Range(result.range(at: 2), in: fullMatch)!])
                    : ""
                let name = result.range(at: 3).location != NSNotFound
                    ? String(fullMatch[Range(result.range(at: 3), in: fullMatch)!])
                    : text

                let qty = unit.isEmpty ? number : "\(number)\(unit)"
                return (name.trimmingCharacters(in: .whitespaces), qty)
            }
        }

        // Match trailing quantity: "Milk x2", "Apples (3)"
        let trailingPattern = #"^(.+?)\s*(?:[xX](\d+)|\((\d+)\))$"#
        if let regex = try? NSRegularExpression(pattern: trailingPattern, options: []),
           let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = result.range(at: 1).location != NSNotFound
                ? String(text[Range(result.range(at: 1), in: text)!])
                : text
            let qty1 = result.range(at: 2).location != NSNotFound
                ? String(text[Range(result.range(at: 2), in: text)!])
                : ""
            let qty2 = result.range(at: 3).location != NSNotFound
                ? String(text[Range(result.range(at: 3), in: text)!])
                : ""
            let qty = qty1.isEmpty ? qty2 : qty1
            if !qty.isEmpty {
                return (name.trimmingCharacters(in: .whitespaces), qty)
            }
        }

        return (text, "1")
    }
}

// MARK: - Confirmation View

struct ShoppingListScanConfirmationView: View {
    @Binding var items: [ScannedShoppingItem]
    var onConfirm: () -> Void
    var onRescan: () -> Void

    @State private var editingItemID: UUID? = nil
    @State private var editText: String = ""

    private var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            if items.isEmpty {
                emptyState
            } else {
                itemsList
            }

            bottomBar
        }
        .navigationTitle("Scanned Items")
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(items.count) items found")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(selectedCount == items.count ? "Deselect All" : "Select All") {
                    let newValue = selectedCount != items.count
                    for i in items.indices {
                        items[i].isSelected = newValue
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No items could be read")
                .font(.headline)
            Text("Try scanning again with better lighting or a clearer image.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Scan Again") {
                onRescan()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var itemsList: some View {
        List {
            ForEach($items) { $item in
                HStack(spacing: 12) {
                    Button {
                        item.isSelected.toggle()
                    } label: {
                        Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor(item.isSelected ? .green : .gray)
                    }
                    .buttonStyle(.plain)

                    if editingItemID == item.id {
                        TextField("Item name", text: $editText, onCommit: {
                            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                                items[idx].name = editText
                            }
                            editingItemID = nil
                        })
                        .textFieldStyle(.roundedBorder)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.body)

                            if item.quantity != "1" {
                                Text("Qty: \(item.quantity)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editText = item.name
                            editingItemID = item.id
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { indexSet in
                items.remove(atOffsets: indexSet)
            }
        }
        .listStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    onRescan()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera")
                        Text("Rescan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onConfirm()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cart.badge.plus")
                        Text("Add \(selectedCount) Items")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
            }
            .padding()
        }
        .background(.ultraThinMaterial)
    }
}
