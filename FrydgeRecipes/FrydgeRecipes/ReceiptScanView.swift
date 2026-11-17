import SwiftUI
import VisionKit
import Vision
import PhotosUI
import PDFKit
import UniformTypeIdentifiers
import CloudKit

// MARK: - Where scanned items land

/// A receipt can fill the personal fridge or any shared frydge the user owns.
/// Frydges shared *with* the user are owner-only-write, so they are never
/// offered as a destination.
enum ReceiptDestination: Hashable {
    case mine
    case shared(CKRecord.ID)
}

/// One entry in the "Add to" picker on the confirmation screen.
struct ReceiptDestinationOption: Identifiable, Hashable {
    let destination: ReceiptDestination
    /// Menu label including the emoji, e.g. "🏠 Kitchen".
    let label: String
    /// Bare name for the confirm button, e.g. "Kitchen".
    let shortName: String

    var id: ReceiptDestination { destination }
}

// MARK: - Parsed receipt item

struct ScannedReceiptItem: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String
    /// Line price actually charged for this item (in dollars), if the receipt showed one.
    var price: Double? = nil
    /// A deal/special note captured from the receipt (e.g. "Special", "was $4.99").
    var promoText: String? = nil
    var isSelected: Bool = true

    var isSpecial: Bool { promoText != nil }

    /// e.g. "$4.50" for display.
    var priceText: String? {
        guard let price else { return nil }
        return String(format: "$%.2f", price)
    }
}

// MARK: - Receipt Scan Flow

struct ReceiptScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var sharedManager: SharedFridgeManager

    /// Where the scan should land when it opens. Scanning from a shared frydge
    /// pre-selects that frydge; the user can still change it before confirming.
    let initialDestination: ReceiptDestination

    /// Explicit rather than memberwise: the private @State properties below
    /// would otherwise make the synthesized init private to this file.
    init(initialDestination: ReceiptDestination = .mine) {
        self.initialDestination = initialDestination
    }

    private enum Phase {
        case choosing
        case processing
        case confirming
    }

    @State private var scannedItems: [ScannedReceiptItem] = []
    @State private var phase: Phase = .choosing
    @State private var receiptTotal: Double = 0
    @State private var receiptStore: String? = nil
    @State private var destination: ReceiptDestination = .mine
    @State private var didSeedDestination = false
    @State private var isSaving = false

    // Import sources
    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choosing:
                    sourceChooser
                case .processing:
                    processingView
                case .confirming:
                    ReceiptScanConfirmationView(
                        items: $scannedItems,
                        destination: $destination,
                        destinationOptions: destinationOptions,
                        isSaving: isSaving,
                        onConfirm: {
                            Task {
                                await addSelectedItems()
                                if importError == nil { dismiss() }
                            }
                        },
                        onRescan: {
                            scannedItems = []
                            phase = .choosing
                        }
                    )
                }
            }
            .onAppear {
                guard !didSeedDestination else { return }
                didSeedDestination = true
                destination = initialDestination
            }
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .choosing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ReceiptDocumentScanner(
                onComplete: { text in
                    showCamera = false
                    finishOCR(text)
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            loadPickedPhoto(newValue)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        // Covers both a file we couldn't read and a failed save into a shared
        // frydge — in either case the message says which.
        .alert("Something went wrong", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Source chooser

    private var sourceChooser: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Add a receipt")
                    .font(.title3.weight(.semibold))
                Text("Scan a paper receipt, or import one from your photos or files.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                Button {
                    showCamera = true
                } label: {
                    Label("Scan with Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showFileImporter = true
                } label: {
                    Label("Choose from Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Reading your receipt...")
                .foregroundColor(.secondary)
        }
    }

    // MARK: OCR handling

    /// Parses recognised text into items and advances to the confirmation step.
    private func finishOCR(_ text: String) {
        scannedItems = ReceiptOCRParser.parse(text)
        receiptTotal = ReceiptOCRParser.extractTotal(text)
        receiptStore = ReceiptOCRParser.detectStore(text)
        phase = .confirming
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) {
        phase = .processing
        Task {
            let image: UIImage?
            if let data = try? await item.loadTransferable(type: Data.self) {
                image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.capture)
            } else {
                image = nil
            }
            await MainActor.run { selectedPhotoItem = nil }

            guard let image else {
                await MainActor.run {
                    importError = "That photo couldn't be opened."
                    phase = .choosing
                }
                return
            }

            let text = await OCRService.recognizeReceipt(image: image)
            await MainActor.run { finishOCR(text) }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            phase = .processing
            Task {
                let text = await Self.recognizeFile(at: url)
                await MainActor.run {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        importError = "No text could be read from that file."
                        phase = .choosing
                    } else {
                        finishOCR(text)
                    }
                }
            }
        }
    }

    /// Reads text from an imported image or PDF file. Handles the
    /// security-scoped access that `.fileImporter` returns for files
    /// outside the app sandbox.
    private static func recognizeFile(at url: URL) async -> String {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf" {
            let images = imagesFromPDF(at: url)
            var pages: [String] = []
            for image in images {
                let t = await OCRService.recognizeReceipt(image: image)
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(t)
                }
            }
            return pages.joined(separator: "\n\n")
        }

        guard let data = try? Data(contentsOf: url),
              let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.capture) else {
            return ""
        }
        return await OCRService.recognizeReceipt(image: image)
    }

    /// Renders each page of a PDF into an image for OCR.
    private static func imagesFromPDF(at url: URL) -> [UIImage] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var images: [UIImage] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // Render at 2x for sharper text recognition.
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.scaleBy(x: scale, y: scale)
                ctx.cgContext.translateBy(x: 0, y: bounds.height)
                ctx.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            images.append(image)
        }
        return images
    }

    /// "My frydge" plus every shared frydge the user owns, and any frydge shared
    /// with them where the owner has approved member receipt scanning.
    private var destinationOptions: [ReceiptDestinationOption] {
        var options: [ReceiptDestinationOption] = [
            ReceiptDestinationOption(destination: .mine, label: "🧊 My frydge", shortName: "Frydge")
        ]

        for anchor in sharedManager.sharedFrydgeAnchors where sharedManager.canScanReceipts(into: anchor) {
            let id = anchor.recordID
            let name = sharedManager.namesByFridge[id]
                ?? (anchor["name"] as? String ?? "Shared frydge")
            let emoji = sharedManager.emojiByFridge[id]
                ?? (anchor["emoji"] as? String ?? "🧊")
            options.append(
                ReceiptDestinationOption(
                    destination: .shared(id),
                    label: "\(emoji) \(name)",
                    shortName: name
                )
            )
        }

        return options
    }

    @MainActor
    private func addSelectedItems() async {
        // Resolve the shared frydge up front. If it's gone (deleted or unshared
        // while the scan was open) stop rather than silently dumping someone's
        // whole shop into the wrong fridge.
        var sharedAnchor: CKRecord? = nil
        if case .shared(let anchorID) = destination {
            guard let match = sharedManager.sharedFrydgeAnchors.first(where: {
                $0.recordID == anchorID && sharedManager.canScanReceipts(into: $0)
            }) else {
                importError = "That shared frydge isn't available any more. Pick another destination and try again."
                return
            }
            sharedAnchor = match
        }

        isSaving = true
        defer { isSaving = false }

        var receiptLines: [String] = []
        var observed: [(name: String, price: Double, promoText: String?)] = []
        var sharedItems: [SharedFridgeManager.SharedFrydgeItem] = []

        for item in scannedItems where item.isSelected {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // Auto-categorise storage and derive an accurate best-before per product.
            let location = FoodStorageClassifier.suggestedLocation(for: name)
            let expiry = FoodStorageClassifier.bestBefore(for: name, location: location)
            let quantity = item.quantity.isEmpty ? "1" : item.quantity

            if sharedAnchor != nil {
                // Batched below into one CloudKit write rather than one per item.
                sharedItems.append(
                    sharedManager.makeSharedFrydgeItem(
                        name: name,
                        quantity: quantity,
                        unit: "",
                        location: location,
                        dietaryTags: [],
                        expirationDate: expiry,
                        lifecycle: StoredIngredient.ItemLifecycle.fridge.rawValue
                    )
                )
            } else {
                frydgeManager.addAutoClassifiedProduct(
                    name: name,
                    quantity: quantity,
                    unit: ""
                )
            }

            // Spend line, enriched with price/deal when we read one.
            var line = item.quantity == "1" ? name : "\(item.quantity) x \(name)"
            if let priceText = item.priceText { line += " — \(priceText)" }
            if item.isSpecial { line += " ⭐️" }
            receiptLines.append(line)

            if let price = item.price {
                observed.append((name: name, price: price, promoText: item.promoText))
            }
        }

        if let sharedAnchor, !sharedItems.isEmpty {
            // Clear first: importItemsAndReload reports failures by setting
            // errorMessage but never clears it, so a stale error from earlier
            // would otherwise look like this import failed.
            sharedManager.errorMessage = nil
            await sharedManager.importItemsAndReload(sharedItems, into: sharedAnchor, scope: sharedManager.scope(for: sharedAnchor))
            if let message = sharedManager.errorMessage, !message.isEmpty {
                importError = message
                return
            }
        }

        // Record the shop as a receipt for spend tracking (Profile → Spending).
        // Spend is tracked per person regardless of which frydge the food went
        // into — it's still money this user spent.
        guard !receiptLines.isEmpty else { return }
        let total = receiptTotal
        let store = receiptStore

        // Feed observed prices into the live price records so future pricing is
        // informed by what was actually paid (including any deals).
        if !observed.isEmpty {
            ObservedPriceStore.shared.record(observed, store: store)
        }

        await ReceiptStore.shared.save(storeName: store, total: total, items: receiptLines)
    }
}

// MARK: - Document Scanner Wrapper

private struct ReceiptDocumentScanner: UIViewControllerRepresentable {
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
                let text = await OCRService.recognizeReceipt(scan: scan)
                await MainActor.run {
                    onComplete(text)
                }
            }
        }
    }
}

// MARK: - Receipt OCR

/// Receipt-specific recognition. Vision emits one observation per text blob,
/// and on a receipt the product name (left column) and its price (right
/// column) usually arrive as *separate* observations. Joining observations in
/// Vision's return order therefore splits every row into a price-less name
/// line and a name-less price line, which defeats the parser's
/// "no price = header junk" rules — names get dropped, header noise survives.
/// Here we rebuild the physical rows from the observation bounding boxes so
/// each product reaches the parser on one line together with its price.
extension OCRService {
    static func recognizeReceipt(scan: VNDocumentCameraScan) async -> String {
        guard scan.pageCount > 0 else { return "" }
        var pages: [String] = []
        for i in 0..<scan.pageCount {
            let text = await recognizeReceipt(image: scan.imageOfPage(at: i))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    static func recognizeReceipt(image: UIImage) async -> String {
        await withCheckedContinuation { cont in
            guard let cgImage = image.cgImage else {
                cont.resume(returning: "")
                return
            }

            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                cont.resume(returning: assembleRows(from: observations))
            }
            request.recognitionLevel = .accurate
            // Language correction "fixes" prices, SKUs, and abbreviated
            // product names into dictionary words — keep the raw strings.
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(returning: "")
            }
        }
    }

    private static func assembleRows(from observations: [VNRecognizedTextObservation]) -> String {
        struct Fragment {
            let text: String
            let box: CGRect
        }

        let fragments: [Fragment] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Fragment(text: candidate.string, box: obs.boundingBox)
        }
        guard !fragments.isEmpty else { return "" }

        // Vision's normalised coordinates put the origin at the bottom-left,
        // so descending midY reads top-to-bottom.
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }

        // Fragments whose vertical centres sit within roughly half a text
        // height of the row anchor are the same physical printed line.
        var rows: [[Fragment]] = []
        var rowAnchor: Fragment? = nil
        for fragment in sorted {
            if let anchor = rowAnchor {
                let tolerance = max(fragment.box.height, anchor.box.height) * 0.6
                if abs(fragment.box.midY - anchor.box.midY) <= tolerance {
                    rows[rows.count - 1].append(fragment)
                    continue
                }
            }
            rows.append([fragment])
            rowAnchor = fragment
        }

        return rows
            .map { row in
                row.sorted { $0.box.minX < $1.box.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}

// MARK: - Receipt OCR Parser

enum ReceiptOCRParser {
    static func parse(_ text: String) -> [ScannedReceiptItem] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var items: [ScannedReceiptItem] = []
        var indexByKey: [String: Int] = [:]
        var seenPricedLine = false

        for line in lines {
            // Deal / discount rows (e.g. "Special -$1.00", "You saved $2") aren't
            // items themselves — attach them as a promo note to the item above.
            if let promo = promoNote(in: line) {
                if let last = items.indices.last {
                    if items[last].promoText == nil { items[last].promoText = promo }
                    // Discount rows carry the markdown ("PRICE SAVER -1.50").
                    // Fold it into the item so the price we keep — and later
                    // record — is the promotional price actually paid.
                    if let discount = discountAmount(in: line),
                       let full = items[last].price, discount < full {
                        items[last].price = ((full - discount) * 100).rounded() / 100
                    }
                }
                continue
            }

            // Date/time stamps ("15.08.26", "15/08/2026 14:32 OP#12") only occur
            // in the header/footer, and a dotted date would otherwise pass for a
            // price — opening the item zone early and turning merchant/location
            // lines into "items".
            if line.range(of: #"\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#,
                          options: .regularExpression) != nil { continue }

            // Capture the line price BEFORE cleanLine strips it away.
            let price = amount(in: line)

            // A store banner line (e.g. "PAK'nSAVE") with no price is a header, not an item.
            if price == nil, detectStore(line) != nil { continue }

            // Header zone: until the first priced line appears, price-less text
            // is the store name, suburb, or legal boilerplate — not groceries.
            if price == nil, !seenPricedLine { continue }
            if price != nil { seenPricedLine = true }

            // A long digit run with no price is transaction plumbing — merchant
            // IDs, auth codes, loose barcodes — never a product.
            if price == nil,
               line.range(of: #"\d{6,}"#, options: .regularExpression) != nil { continue }

            let cleaned = cleanLine(line)
            guard !cleaned.isEmpty else { continue }

            if looksLikeNonItem(cleaned, hasPrice: price != nil) { continue }

            let (name, quantity) = extractQuantity(from: cleaned)
            let normalizedKey = name.lowercased()
            guard !normalizedKey.isEmpty, normalizedKey.count >= 2 else { continue }

            if let existingIdx = indexByKey[normalizedKey] {
                // Same product printed twice — keep the first row but backfill
                // the price and any promo marker.
                if items[existingIdx].price == nil { items[existingIdx].price = price }
                if items[existingIdx].promoText == nil {
                    items[existingIdx].promoText = inlinePromoNote(in: line)
                }
                continue
            }

            indexByKey[normalizedKey] = items.count
            items.append(
                ScannedReceiptItem(
                    name: name,
                    quantity: quantity,
                    price: price,
                    promoText: inlinePromoNote(in: line)
                )
            )
        }

        return items
    }

    /// Detects a standalone deal/discount row and returns a short human note.
    /// Returns nil for normal item and header rows.
    private static func promoNote(in line: String) -> String? {
        let lower = line.lowercased()
        // "^Denotes special price" is the legend explaining the caret marker,
        // not a deal row — skip it entirely (looksLikeNonItem drops it too).
        if lower.contains("denotes") { return nil }
        let dealMarkers: [String] = ["you save", "you saved", "save $", "save ¢", "multibuy",
                           "multi buy", "multi-buy", "mix & match", "club price",
                           "member price", "members price", "% off",
                           "price saver", "saver price", "markdown", "instore special"]
        // "special"/"discount"/"promo" only count as a deal row when they're not
        // part of a longer product name (short-ish rows).
        let softMarkers: [String] = ["special", "discount", "promo", "rollback", "was $"]

        if dealMarkers.contains(where: { lower.contains($0) }) {
            return cleanPromo(line)
        }
        if softMarkers.contains(where: { lower.contains($0) }), line.count <= 30 {
            return cleanPromo(line)
        }
        return nil
    }

    /// A special marker printed on the item line itself. Woolworths/Countdown
    /// receipts flag a promotional price with a caret (e.g. "4.99^"); a trailing
    /// asterisk is the same idea at other chains.
    private static func inlinePromoNote(in line: String) -> String? {
        if line.contains("^") { return "Promo price" }
        if line.range(of: #"\*\s*$"#, options: .regularExpression) != nil { return "Special" }
        return nil
    }

    /// The markdown on a discount row, e.g. "PRICE SAVER -1.50" → 1.5.
    private static func discountAmount(in line: String) -> Double? {
        let pattern = #"-\s*\$?\s*(\d+)\.(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let m = re.matches(in: line, range: NSRange(location: 0, length: ns.length)).last,
              m.numberOfRanges >= 3 else { return nil }
        return Double("\(ns.substring(with: m.range(at: 1))).\(ns.substring(with: m.range(at: 2)))")
    }

    private static func cleanPromo(_ line: String) -> String {
        let s = line
            .replacingOccurrences(of: #"^[\-\*\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Special" : String(s.prefix(40))
    }

    /// Pulls the grand total from receipt text. Prefers lines labelled "total"
    /// (excluding "subtotal"); the grand total is the largest such amount.
    static func extractTotal(_ text: String) -> Double {
        let lines = text.components(separatedBy: .newlines)
        var candidates: [Double] = []
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.contains("total"),
                  !lower.contains("subtotal"), !lower.contains("sub total") else { continue }
            if let amt = amount(in: line) {
                candidates.append(amt)
            } else if i + 1 < lines.count, let amt = amount(in: lines[i + 1]) {
                candidates.append(amt)
            }
        }
        return candidates.max() ?? 0
    }

    /// Best trailing money amount on a line, e.g. "TOTAL   $48.50" → 48.5.
    private static func amount(in line: String) -> Double? {
        let pattern = #"\$?\s*(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.last, m.numberOfRanges >= 3 else { return nil }
        let whole = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
        let frac = ns.substring(with: m.range(at: 2))
        return Double("\(whole).\(frac)")
    }

    /// Identifies the NZ retailer from receipt header text, if recognisable.
    static func detectStore(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("pak") && lower.contains("save") { return "Pak'nSave" }
        if lower.contains("new world") { return "New World" }
        if lower.contains("four square") { return "Four Square" }
        if lower.contains("woolworths") || lower.contains("countdown") { return "Woolworths" }
        if lower.contains("the warehouse") { return "The Warehouse" }
        return nil
    }

    private static func cleanLine(_ line: String) -> String {
        var cleaned = line

        // The caret is the promo-price marker (captured separately as a promo
        // note) — it is never part of a product name, and OCR often glues it to
        // the price or the name ("4.99^", "MILK^").
        cleaned = cleaned.replacingOccurrences(of: "^", with: " ")

        // Strip weight-and-unit-price suffixes commonly seen on NZ receipts, e.g.
        // "BANANAS 0.345 KG @ $2.99/KG  $1.03" -> "BANANAS".
        // Run this before the trailing-price strip so we hit the embedded $/kg first.
        let weightUnitPricePattern = #"\s*\d+(?:[.,]\d+)?\s*(?:KG|G|GM|GMS|ML|L|LB|LBS|OZ)\s*@?\s*\$?\d+(?:[.,]\d+)?\s*(?:/\s*\w+)?"#
        cleaned = cleaned.replacingOccurrences(
            of: weightUnitPricePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove trailing price patterns ($12.99, 12.99, $1,234.56), tolerating
        // trailing receipt markers ("4.99 *", "4.99 #").
        let pricePattern = #"\s*\$?\d{1,3}(?:,\d{3})*\.\d{2}[\s\*#]*$"#
        cleaned = cleaned.replacingOccurrences(of: pricePattern, with: "", options: .regularExpression)

        // Barcodes / merchant numbers embedded mid-line (6+ digit runs).
        cleaned = cleaned.replacingOccurrences(of: #"\b\d{6,}\b"#, with: " ", options: .regularExpression)

        // Strip per-unit suffixes that remain after the price is gone
        // (e.g. "MILK 2L /kg", "BREAD /ea").
        let perUnitPattern = #"\s*/\s*(?:KG|G|ML|L|LB|EA|EACH)\s*$"#
        cleaned = cleaned.replacingOccurrences(
            of: perUnitPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove leading item codes / SKUs (sequences of digits at the start)
        let skuPattern = #"^\d{4,}\s+"#
        cleaned = cleaned.replacingOccurrences(of: skuPattern, with: "", options: .regularExpression)

        // Remove common receipt suffixes
        let suffixPattern = #"\s+(EA|EACH|@|QTY|FP|MR|SPECIAL|PRICE REDUCED|REDUCED|CLUB PRICE|MEMBERS PRICE)\s*$"#
        cleaned = cleaned.replacingOccurrences(of: suffixPattern, with: "", options: [.regularExpression, .caseInsensitive])

        // Remove trailing asterisks or hash marks used as receipt markers
        cleaned = cleaned.replacingOccurrences(of: #"[\*#]+\s*$"#, with: "", options: .regularExpression)

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private static func looksLikeNonItem(_ text: String, hasPrice: Bool = false) -> Bool {
        let lower = text.lowercased()

        // Receipt header/footer / loyalty / payment / discount-row fragments.
        // These are long enough to match as plain substrings safely.
        let skipPatterns: [String] = [
            "subtotal", "sub total", "eftpos",
            "visa", "mastercard", "change", "receipt",
            "thank you", "thanks", "welcome", "rewards", "points",
            "savings", "you saved", "balance",
            "register", "operator", "transaction",
            "abn", "acn", "phone", "tel", "fax", "www.", "http",
            ".com", ".co.nz", ".co.uk", "loyalty",
            "clubcard", "flybuys", "onecard", "everyday rewards",
            "number of items", "item count", "payment",
            "debit", "credit", "approved", "authorised", "auth code",
            "merchant", "terminal", "invoice", "denotes",
            // Discount / special row labels — these would otherwise look like items
            "special ", "special:", "save $", "save ¢", "voucher", "promotion",
            "promo ", "discount", "club price", "members price", "you save",
            "rollback", "earned", "% off", "% discount", "price saver",
            "multibuy", "multi buy", "multi-buy", "mix & match"
        ]
        for pattern in skipPatterns {
            if lower.contains(pattern) { return true }
        }

        // Short tokens are matched on whole words only, so they can't swallow
        // real products ("DATES", "CASHEWS", "REFRIED BEANS", "TIMTAMS").
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let skipWords: Set<String> = ["total", "gst", "tax", "cash", "card", "date",
                                      "time", "store", "ref", "member", "batch",
                                      "pos", "stan", "seq"]
        if !words.isDisjoint(with: skipWords) { return true }

        // Street addresses from the receipt header: a house number followed by a
        // street-suffix word ("286 Mount Wellington Hwy"), or a corner marker.
        let streetSuffix = #"(road|rd|street|drive|avenue|ave|highway|hwy|crescent|cres|terrace|parade|esplanade|quay|boulevard|blvd|motorway)"#
        if text.range(of: #"^\d{1,4}[a-z]?\s+\S+.*\b"# + streetSuffix + #"\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if lower.range(of: #"\b(cnr|corner of)\b"#, options: .regularExpression) != nil { return true }
        // A line simply ending in a street suffix with no price is address spill.
        if !hasPrice,
           lower.range(of: #"\b"# + streetSuffix + #"\s*$"#, options: .regularExpression) != nil { return true }

        // Phone-like digit groups ("09 570 5123") with no price.
        if !hasPrice,
           text.range(of: #"\b\d{2,4}[ -]\d{3,4}[ -]\d{3,4}\b"#, options: .regularExpression) != nil { return true }

        // A bare "SPECIAL"/"SAVED" word — or a city/country line from the
        // address block — on its own line.
        let bareLine = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let bareSkip: Set<String> = ["special", "saved", "save", "discount", "promotion",
                                     "auckland", "wellington", "christchurch", "hamilton",
                                     "tauranga", "dunedin", "new zealand", "nz"]
        if bareSkip.contains(bareLine) { return true }

        // Department / aisle section headers commonly printed in all caps.
        if isLikelyDepartmentHeader(text) { return true }

        // Lines that are mostly digits/symbols (prices, codes, dates, etc.)
        let letterCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letterCount < 2 { return true }

        // Very long lines are likely addresses or disclaimers. Relaxed from 60
        // to 80 so longer product names ("Anchor Blue Top Milk 2 Litre") survive.
        if text.count > 80 { return true }

        // Lines that are all uppercase and very short (likely section headers)
        if text.count <= 3 && text == text.uppercased() { return true }

        return false
    }

    /// Detects common supermarket section / department headers that get printed
    /// in all caps on receipts (e.g. "FRESH PRODUCE", "BAKERY", "DAIRY & DELI").
    private static func isLikelyDepartmentHeader(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Must be all uppercase (anything with lowercase is unlikely to be a header)
        guard trimmed == trimmed.uppercased() else { return false }

        // Departments are short — one to three words, no digits
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        let wordCount = trimmed.split(separator: " ").count
        guard (1...3).contains(wordCount) else { return false }

        let lower = trimmed.lowercased()
        let departments: Set<String> = [
            "produce", "fresh produce", "dairy", "bakery", "meat", "seafood",
            "grocery", "frozen", "frozen foods", "deli", "delicatessen",
            "beverage", "beverages", "drinks", "household", "health & beauty",
            "health and beauty", "personal care", "baby", "pets", "pet care",
            "snacks", "confectionery", "alcohol", "wine", "beer",
            "fruit & veg", "fruit and veg", "pantry", "chilled",
            "fresh", "produce dept", "produce department"
        ]

        return departments.contains(lower)
    }

    private static func extractQuantity(from text: String) -> (name: String, quantity: String) {
        // Match leading quantity: "2 x Milk", "3x Bread", "2 Apples"
        let qtyPattern = #"^(\d+)\s*[xX]?\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: qtyPattern, options: []),
           let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let number = result.range(at: 1).location != NSNotFound
                ? String(text[Range(result.range(at: 1), in: text)!])
                : "1"
            let name = result.range(at: 2).location != NSNotFound
                ? String(text[Range(result.range(at: 2), in: text)!])
                : text

            if let qty = Int(number), qty > 0 && qty < 100 {
                return (name.trimmingCharacters(in: .whitespaces), "\(qty)")
            }
        }

        return (text, "1")
    }
}

// MARK: - Confirmation View

struct ReceiptScanConfirmationView: View {
    @Binding var items: [ScannedReceiptItem]
    @Binding var destination: ReceiptDestination
    var destinationOptions: [ReceiptDestinationOption] = [
        ReceiptDestinationOption(destination: .mine, label: "🧊 My frydge", shortName: "Frydge")
    ]
    var isSaving: Bool = false
    var onConfirm: () -> Void
    var onRescan: () -> Void

    @State private var editingItemID: UUID? = nil
    @State private var editText: String = ""

    private var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    /// Name of the chosen destination, for the confirm button.
    private var destinationShortName: String {
        destinationOptions.first { $0.destination == destination }?.shortName ?? "Frydge"
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
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Receipt Items")
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

            // Only worth showing once there's somewhere else for the shop to go.
            if destinationOptions.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Add to")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("Add to", selection: $destination) {
                        ForEach(destinationOptions) { option in
                            Text(option.label).tag(option.destination)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Add these items to")
                .accessibilityValue(destinationShortName)
            }

            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                Text("Storage & best-before are set automatically per item — edit any item later in your fridge.")
                    .font(.caption)
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal)

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
            Text("Try scanning again with better lighting or a flatter receipt.")
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
                receiptRow($item)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
    }

    @ViewBuilder
    private func receiptRow(_ item: Binding<ScannedReceiptItem>) -> some View {
        let value = item.wrappedValue
        HStack(spacing: 12) {
            Text(FoodEmoji.emoji(for: value.name))
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )

            if editingItemID == value.id {
                TextField("Item name", text: $editText, onCommit: {
                    if let idx = items.firstIndex(where: { $0.id == value.id }) {
                        items[idx].name = editText
                    }
                    editingItemID = nil
                })
                .textFieldStyle(.roundedBorder)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if value.quantity != "1" {
                            Text("Qty \(value.quantity)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let priceText = value.priceText {
                            Text(priceText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if value.isSpecial {
                            Text("DEAL")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    editText = value.name
                    editingItemID = value.id
                }
            }

            Button {
                item.wrappedValue.isSelected.toggle()
            } label: {
                Image(systemName: value.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(value.isSelected ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(value.isSelected ? 0.06 : 0.03), lineWidth: 1)
        )
        .opacity(value.isSelected ? 1 : 0.55)
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
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "refrigerator")
                        }
                        Text(isSaving ? "Adding…" : "Add \(selectedCount) to \(destinationShortName)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || isSaving)
            }
            .padding()
        }
        .background(.ultraThinMaterial)
    }
}
