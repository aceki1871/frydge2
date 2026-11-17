import SwiftUI
import UIKit
import Vision
import VisionKit
import AVFoundation
import AudioToolbox

struct BarcodeScannerView: UIViewControllerRepresentable {
    @Binding var isShowing: Bool
    @Binding var scannedBarcode: String
    @Binding var productDetails: ProductProtocol?

    /// Optional callback used when a nutrition table is recognized (OCR). If provided, the scanner will call this and dismiss.
    var onNutritionScanned: ((NutritionLabel) -> Void)? = nil
  
    /// Optional callback used when barcode mode can infer a front-label product name from visible text.
    var onFrontLabelDetected: ((String) -> Void)? = nil

    /// When set, the scanner runs in continuous mode: each resolved product is
    /// reported through this callback and the camera keeps running (it does NOT
    /// dismiss). Used by in-store basket scanning to tick items off as you go.
    var onProductResolved: ((ProductProtocol) -> Void)? = nil
  
    enum ScanMode: Int {
        case barcode = 0
        case nutrition = 1
        case frontLabel = 2

        var title: String {
            switch self {
            case .barcode: return "Barcode"
            case .nutrition: return "Nutrition"
            case .frontLabel: return "Front Label"
            }
        }
    }

    struct NutritionLabel: Equatable, Codable {
        var energyKcal: Double?
        var energyKj: Double?
        var fat: Double?
        var saturates: Double?
        var carbs: Double?
        var sugars: Double?
        var fibre: Double?
        var protein: Double?
        var salt: Double?

        /// Raw lines used to derive the values (useful for debugging / UI confirmation).
        var rawLines: [String] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ContainerVC {
        let vc = ContainerVC()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ContainerVC, context: Context) {
        // no-op
    }

    // MARK: - Inner container that notifies when on-screen
    final class ContainerVC: UIViewController {
        weak var coordinator: Coordinator?
        private var didAttach = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didAttach else { return }
            didAttach = true
            coordinator?.attachScanner(to: self)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            coordinator?.stopScanning()
        }
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, DataScannerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: BarcodeScannerView
        private weak var containerVC: ContainerVC?
        private var scanner: DataScannerViewController?
        private weak var suggestionButton: UIButton?
        private weak var statusLabel: UILabel?
        private var mode: ScanMode = .barcode

        /// Continuous (basket) mode: barcodes only, no per-frame OCR, keep the
        /// camera running after each hit.
        private var isContinuous: Bool { parent.onProductResolved != nil }
        private var defaultStatusText: String {
            isContinuous ? "Point at a barcode to tick it off" : "Point at a barcode or the product label"
        }

        /// Barcode currently being looked up, and when the last hit resolved,
        /// so an item still in frame isn't re-scanned the instant it resolves.
        private var resolvingCode: String?
        private var lastResolvedCode: String?
        private var lastResolvedTime: CFTimeInterval = 0
        private let rescanCooldown: CFTimeInterval = 3.0

        /// Barcodes already tried and not found — so the always-on scanner doesn't
        /// re-hit the network for the same unresolvable code every frame.
        private var failedCodes = Set<String>()
        /// The label-derived name currently offered on the suggestion chip.
        private var pendingSuggestion: String?
        private var lastSuggestionUpdate: CFTimeInterval = 0

        // Barcode awaiting a packaging-photo fallback (set before presenting the camera).
        private var pendingPhotoBarcode: String?

        // True while a barcode is being resolved (or the photo fallback is up).
        // The live scanner keeps re-detecting the same code every frame, so
        // without this a second lookup races the first and can dismiss the
        // photo prompt before the user sees it.
        private var isResolving = false

        // de-dupe throttle
        private var lastCode: String?
        private var lastTime: CFTimeInterval = 0
        private var recentVisibleTextLines: [String] = []
        private var lastFrontLabelName: String?
        private var lastFrontLabelLookupTime: CFTimeInterval = 0
        private let groceryWorkerBaseURL = "https://grocery-price-server.davekitson-read.workers.dev"

        init(_ parent: BarcodeScannerView) { self.parent = parent }

        // Attach after container is visible
        func attachScanner(to container: ContainerVC) {
            containerVC = container

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        granted ? self.embedScanner() : self.showLabel("Camera access denied. Enable in Settings.")
                    }
                }
            case .authorized:
                embedScanner()
            default:
                showLabel("Camera access denied. Enable in Settings.")
            }
        }

        private func embedScanner() {
            guard let container = containerVC else { return }
            guard DataScannerViewController.isSupported else { showLabel("Scanner not supported on this device."); return }
            guard DataScannerViewController.isAvailable else { showLabel("Scanner unavailable right now."); return }

            let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128, .code39]
            // Live text recognition on every frame is the expensive part of
            // the pipeline. The basket only needs barcodes, so skip OCR there
            // and prefer frame rate over resolution.
            let dataTypes: Set<DataScannerViewController.RecognizedDataType> = isContinuous
                ? [.barcode(symbologies: symbologies)]
                : [.barcode(symbologies: symbologies), .text()]
            let s = DataScannerViewController(
                recognizedDataTypes: dataTypes,
                qualityLevel: isContinuous ? .fast : .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: true,
                isPinchToZoomEnabled: true,
                isHighlightingEnabled: true
            )
            s.delegate = self
            scanner = s

            // Embed as child (no modal presentation)
            container.addChild(s)
            s.view.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(s.view)
            NSLayoutConstraint.activate([
                s.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                s.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                s.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                s.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
            s.didMove(toParent: container)

            // Overlay label
            let label = UILabel()
            label.text = defaultStatusText
            label.textColor = .white
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            s.view.addSubview(label)
            statusLabel = label
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor, constant: 8),
                label.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: container.view.widthAnchor, multiplier: 0.9)
            ])

            // Live "tap to add" suggestion chip. The camera stays running and
            // reads barcodes + label text together; when a barcode can't be
            // resolved but the label yields a name, this chip surfaces it.
            // Hidden until there's something to suggest.
            var suggestionConfig = UIButton.Configuration.filled()
            suggestionConfig.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.92)
            suggestionConfig.baseForegroundColor = .white
            suggestionConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
            suggestionConfig.background.cornerRadius = 22
            suggestionConfig.titleAlignment = .center
            suggestionConfig.titleLineBreakMode = .byWordWrapping
            suggestionConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = .systemFont(ofSize: 16, weight: .semibold)
                return updated
            }
            let suggestion = UIButton(configuration: suggestionConfig)
            suggestion.titleLabel?.numberOfLines = 2
            suggestion.translatesAutoresizingMaskIntoConstraints = false
            suggestion.isHidden = true
            suggestion.addAction(UIAction { [weak self] _ in
                self?.commitSuggestion()
            }, for: .touchUpInside)
            s.view.addSubview(suggestion)
            suggestionButton = suggestion
            NSLayoutConstraint.activate([
                suggestion.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
                suggestion.bottomAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                suggestion.widthAnchor.constraint(lessThanOrEqualTo: container.view.widthAnchor, multiplier: 0.9)
            ])

            // Close button
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.tintColor = .white
            close.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            close.layer.cornerRadius = 16
            close.translatesAutoresizingMaskIntoConstraints = false
            close.addAction(UIAction { [weak self] _ in
                self?.parent.isShowing = false
                self?.stopScanning()
            }, for: .touchUpInside)
            s.view.addSubview(close)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: container.view.leadingAnchor, constant: 16),
                close.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor, constant: 8),
                close.widthAnchor.constraint(equalToConstant: 32),
                close.heightAnchor.constraint(equalToConstant: 32)
            ])

            // Start scanning after embed on main thread
            DispatchQueue.main.async {
                do { try s.startScanning() }
                catch { print("[Scanner] startScanning failed: \(error.localizedDescription)") }
            }
        }

        func stopScanning() {
            guard let s = scanner else { return }

            // `DataScannerViewController.stopScanning()` is non-throwing on this SDK.
            if s.isScanning {
                s.stopScanning()
            }

            s.willMove(toParent: nil)
            s.view.removeFromSuperview()
            s.removeFromParent()
            scanner = nil
        }

        // MARK: - Delegate
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(items: allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(items: allItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {}

        /// Unified handler: the camera stays running and reads barcodes and label
        /// text at the same time. A barcode resolves automatically; if it can't be
        /// found (or there's no barcode), the label text feeds the "tap to add" chip.
        private func handle(items: [RecognizedItem]) {
            if !isContinuous {
                recentVisibleTextLines = extractTextLines(from: items)
                updateSuggestion(from: items)
            }

            for item in items {
                if case let .barcode(b) = item,
                   let value = b.payloadStringValue,
                   !value.isEmpty,
                   !failedCodes.contains(value) {
                    handleBarcode(value)
                    break
                }
            }
        }

        /// Infers a product name from the visible label and offers it on the chip.
        /// Throttled so it doesn't churn every frame.
        private func updateSuggestion(from items: [RecognizedItem]) {
            let now = CACurrentMediaTime()
            guard now - lastSuggestionUpdate > 0.4 else { return }
            lastSuggestionUpdate = now

            // Prefer the most prominent (largest) text — on a can or bottle the
            // brand is the biggest thing, even though it's short and its letters
            // wrap around the curve. Fall back to the longest-line heuristic.
            let candidate = mostProminentLabelName(from: items)
                ?? inferFrontLabelName(from: recentVisibleTextLines)

            guard let name = candidate, !name.isEmpty, name != pendingSuggestion else { return }
            pendingSuggestion = name

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onFrontLabelDetected?(name)
                self.suggestionButton?.configuration?.title = "Add “\(name)”"
                self.suggestionButton?.isHidden = false
            }
        }

        /// User tapped the chip — treat the inferred label name as the product.
        @MainActor private func commitSuggestion() {
            guard let name = pendingSuggestion, !name.isEmpty else { return }
            AudioServicesPlaySystemSound(SystemSoundID(1520))
            let product = SimpleProduct(
                barcode: parent.scannedBarcode,
                productName: name,
                ingredientsList: nil,
                quantityValue: nil,
                imageURL: nil
            )
            finish(with: product)
        }

        /// A scanned barcode wasn't in any database. Keep the camera rolling and
        /// let the live label suggestion take over — no teardown, no photo picker.
        @MainActor private func markBarcodeUnresolved(_ barcode: String) {
            failedCodes.insert(barcode)
            isResolving = false
            resolvingCode = nil
            setStatus(isContinuous ? "Not found — try another item" : "Not found — read the label instead", revertAfter: 1.8)
            AudioServicesPlaySystemSound(SystemSoundID(1107))
        }

        /// Updates the top overlay label, optionally reverting to the default
        /// prompt after a delay. Always on main.
        private func setStatus(_ text: String, revertAfter delay: TimeInterval? = nil) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statusLabel?.text = text
                guard let delay else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.statusLabel?.text == text else { return }
                    self.statusLabel?.text = self.defaultStatusText
                }
            }
        }
        private func attemptFrontLabelLookup(lines: [String]) {
            guard mode == .frontLabel else { return }
            guard let inferredName = inferFrontLabelName(from: lines), !inferredName.isEmpty else { return }

            let now = CACurrentMediaTime()
            if inferredName == lastFrontLabelName, now - lastFrontLabelLookupTime < 1.0 { return }
            lastFrontLabelName = inferredName
            lastFrontLabelLookupTime = now

            DispatchQueue.main.async { [weak self] in
                self?.parent.onFrontLabelDetected?(inferredName)
            }

            fetchFrontLabelCandidate(query: inferredName)
        }

        private func fetchFrontLabelCandidate(query: String) {
            Task { [weak self] in
                guard let self else { return }
                guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: "\(groceryWorkerBaseURL)/search-products?q=\(encoded)&limit=1") else {
                    return
                }

                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
                    let decoded = try JSONDecoder().decode(GroceryWorkerSearchProductsResponse.self, from: data)

                    await MainActor.run {
                        if let best = decoded.products.first?.name, !best.isEmpty {
                            self.parent.onFrontLabelDetected?(best)
                        } else {
                            self.parent.onFrontLabelDetected?(query)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.parent.onFrontLabelDetected?(query)
                    }
                }
            }
        }

        private func handleBarcode(_ value: String) {
            guard !isResolving else { return } // a lookup (or photo prompt) is already in flight
            let now = CACurrentMediaTime()
            if value == lastCode, now - lastTime < 0.6 { return } // throttle dupes
            // The item just ticked off is usually still in frame; give the user
            // time to move on before the same code can fire again.
            if value == lastResolvedCode, now - lastResolvedTime < rescanCooldown { return }
            lastCode = value
            lastTime = now
            isResolving = true
            resolvingCode = value
            AudioServicesPlaySystemSound(SystemSoundID(1520))
            setStatus("Looking up…")

            parent.scannedBarcode = value
            
            // ✅ Enhanced: Fetch product details with better accuracy
            fetchProductDetailsEnhanced(barcode: value)
        }
        
        /// Enhanced product fetch with fallback chain for better accuracy.
        /// If every database and the live OCR come up empty, we don't give up —
        /// we ask the user to photograph the packaging and read the name off it.
        private func fetchProductDetailsEnhanced(barcode: String) {
            Task { [weak self] in
                guard let self else { return }

                // 1) Resolve against every product database we have access to.
                if let product = await self.resolveViaDatabases(barcode) {
                    self.finish(with: product)
                    return
                }

                // 2) Databases don't know this code — keep the camera running and
                // hand off to the live label suggestion ("Add …" chip). No session
                // teardown, so nothing to freeze.
                self.markBarcodeUnresolved(barcode)
            }
        }

        /// Runs the barcode through every product database in priority order.
        /// Returns nil only when none of them recognise the code.
        private func resolveViaDatabases(_ barcode: String) async -> ProductProtocol? {
            // Phase 1 — the two direct barcode indexes, raced. Previously these
            // ran one after another, so a miss on the first cost its full
            // timeout before the second even started.
            if let product = await Self.firstHit([
                { try? await OpenFoodFactsService.shared.fetchByBarcode(barcode) },   // most accurate for groceries
                { await self.fetchFromGroceryWorker(barcode: barcode) }               // NZ grocery worker
            ]) {
                return product
            }
            // Phase 2 — the broader, slower fallbacks, also raced.
            return await Self.firstHit([
                { await self.searchGroceryWorker(query: barcode, barcode: barcode) }, // GTIN in page metadata
                { try? await UPCItemDBService.shared.lookup(barcode) }               // general retail / non-food
            ])
        }

        /// Runs the lookups concurrently and returns the first non-nil result,
        /// cancelling the rest. Returns nil only when every lookup missed.
        private static func firstHit(_ lookups: [@Sendable () async -> ProductProtocol?]) async -> ProductProtocol? {
            await withTaskGroup(of: ProductProtocol?.self) { group in
                for lookup in lookups {
                    group.addTask { await lookup() }
                }
                var hit: ProductProtocol?
                for await result in group {
                    if let result {
                        hit = result
                        group.cancelAll()
                        break
                    }
                }
                return hit
            }
        }

        /// Turns raw OCR label lines into a product, preferring the on-device
        /// model (iOS 26+) and falling back to the heuristic name picker.
        /// Category-agnostic, so it works for food and household products alike.
        private func buildProductFromOCR(lines: [String], barcode: String?) async -> ProductProtocol? {
            let cleaned = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { return nil }

            if let extracted = await LabelScanService.shared.extract(from: cleaned),
               !extracted.name.isEmpty {
                let (num, _) = OFFProduct.parseQuantityAndUnit(from: extracted.quantity)
                return SimpleProduct(
                    barcode: barcode,
                    productName: extracted.name,
                    ingredientsList: extracted.ingredients.isEmpty ? nil : extracted.ingredients,
                    quantityValue: num,
                    imageURL: nil
                )
            }

            if let inferredName = self.inferFrontLabelName(from: cleaned), !inferredName.isEmpty {
                return SimpleProduct(
                    barcode: barcode,
                    productName: inferredName,
                    ingredientsList: nil,
                    quantityValue: nil,
                    imageURL: nil
                )
            }
            return nil
        }

        /// Commits a resolved product back to the SwiftUI binding and closes the scanner.
        @MainActor private func finish(with product: ProductProtocol) {
            // Continuous mode (in-store basket): report the hit and keep scanning.
            if let onProductResolved = parent.onProductResolved {
                AudioServicesPlaySystemSound(SystemSoundID(1520))
                onProductResolved(product)
                // Cool down on this code only, so the next item scans straight
                // away but the one still in frame doesn't fire in a loop.
                lastResolvedCode = resolvingCode
                lastResolvedTime = CACurrentMediaTime()
                lastCode = nil
                resolvingCode = nil
                isResolving = false
                let name = product.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                setStatus(name.isEmpty ? "Found" : "✓ \(name)", revertAfter: 1.6)
                return
            }
            parent.productDetails = product
            parent.isShowing = false
            stopScanning()
        }

        /// "Unknown" sentinel lets downstream views show a blank editable field.
        @MainActor private func finishUnknown(barcode: String) {
            let unknown = SimpleProduct(
                barcode: barcode,
                productName: "Unknown",
                ingredientsList: nil,
                quantityValue: nil,
                imageURL: nil
            )
            finish(with: unknown)
        }

        // MARK: - Packaging-photo backup loop

        /// Offers the user a chance to photograph the packaging when the barcode
        /// couldn't be resolved. Reading the label works for foods and household
        /// products alike, since it's plain OCR + name inference.
        @MainActor private func promptPackagingPhoto(barcode: String) {
            guard let container = containerVC else {
                finishUnknown(barcode: barcode)
                return
            }
            // Something is already presented (e.g. this alert, from a racing
            // duplicate detection) — never tear the scanner down underneath it.
            guard container.presentedViewController == nil else { return }

            let alert = UIAlertController(
                title: "Couldn't identify this item",
                message: "Take a photo of the front of the packaging and we'll read the name off the label.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
                self?.presentPackagingCamera(barcode: barcode)
            })
            alert.addAction(UIAlertAction(title: "Scan Again", style: .default) { [weak self] _ in
                // Let the live scanner have another go at it.
                self?.lastCode = nil
                self?.isResolving = false
            })
            alert.addAction(UIAlertAction(title: "Enter Manually", style: .cancel) { [weak self] _ in
                self?.finishUnknown(barcode: barcode)
            })
            container.present(alert, animated: true)
        }

        @MainActor private func presentPackagingCamera(barcode: String) {
            guard UIImagePickerController.isSourceTypeAvailable(.camera),
                  let container = containerVC else {
                finishUnknown(barcode: barcode)
                return
            }

            pendingPhotoBarcode = barcode
            // Release the live capture session before the picker claims the camera.
            // VisionKit tears the AVCaptureSession down asynchronously, so present
            // the picker on the next runloop turns — presenting synchronously races
            // the release and leaves the picker with a frozen, uncapturable preview.
            stopScanning()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak container] in
                guard let self, let container, container.presentedViewController == nil else {
                    self?.finishUnknown(barcode: barcode)
                    return
                }
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.delegate = self
                container.present(picker, animated: true)
            }
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let barcode = pendingPhotoBarcode ?? parent.scannedBarcode
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                if let image {
                    self.processPackagingPhoto(image, barcode: barcode)
                } else {
                    Task { @MainActor in self.finishUnknown(barcode: barcode) }
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            let barcode = pendingPhotoBarcode ?? parent.scannedBarcode
            picker.dismiss(animated: true) { [weak self] in
                Task { @MainActor in self?.finishUnknown(barcode: barcode) }
            }
        }

        /// Reads a photographed package: retries the databases with any barcode
        /// visible in the still, then OCRs the label to infer a product name.
        private func processPackagingPhoto(_ image: UIImage, barcode: String) {
            Task { [weak self] in
                guard let self else { return }

                // The still shot may capture a barcode the live pass missed.
                if let detected = await self.detectBarcode(in: image),
                   let product = await self.resolveViaDatabases(detected) {
                    self.finish(with: product)
                    return
                }

                // OCR the packaging and infer the name (food or household product).
                let lines = await self.recognizeText(in: image)
                if let product = await self.buildProductFromOCR(lines: lines, barcode: barcode) {
                    self.finish(with: product)
                    return
                }

                // Nothing readable — hand back an editable blank.
                self.finishUnknown(barcode: barcode)
            }
        }

        // MARK: - Vision helpers (still-image barcode + OCR)

        private func detectBarcode(in image: UIImage) async -> String? {
            guard let cg = image.cgImage else { return nil }
            let orientation = image.cgOrientation
            return await Task.detached(priority: .userInitiated) {
                var payload: String?
                let request = VNDetectBarcodesRequest { req, _ in
                    payload = (req.results as? [VNBarcodeObservation])?
                        .compactMap { $0.payloadStringValue }
                        .first { !$0.isEmpty }
                }
                request.symbologies = [.ean13, .ean8, .upce, .code128, .code39]
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
                try? handler.perform([request])
                return payload
            }.value
        }

        private func recognizeText(in image: UIImage) async -> [String] {
            guard let cg = image.cgImage else { return [] }
            let orientation = image.cgOrientation
            return await Task.detached(priority: .userInitiated) {
                var lines: [String] = []
                let request = VNRecognizeTextRequest { req, _ in
                    lines = (req.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } ?? []
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
                try? handler.perform([request])
                return lines
            }.value
        }
        
        /// Fetch product from grocery worker API
        private func fetchFromGroceryWorker(barcode: String) async -> ProductProtocol? {
            guard let url = URL(string: "\(groceryWorkerBaseURL)/product-by-barcode?barcode=\(barcode)") else {
                return nil
            }
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return nil
                }
                
                let decoded = try JSONDecoder().decode(GroceryWorkerProductResponse.self, from: data)
                
                return SimpleProduct(
                    barcode: barcode,
                    productName: decoded.name,
                    ingredientsList: decoded.description,
                    quantityValue: decoded.quantity,
                    imageURL: decoded.imageURL
                )
                
            } catch {
                print("[Scanner] Grocery worker lookup failed: \(error.localizedDescription)")
                return nil
            }
        }

        /// Fallback: search the grocery worker by an arbitrary query (we pass the
        /// barcode itself). NZ supermarket index pages embed GTINs in metadata,
        /// so this finds many products that the direct barcode endpoint misses.
        private func searchGroceryWorker(query: String, barcode: String?) async -> ProductProtocol? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "\(groceryWorkerBaseURL)/search-products?q=\(encoded)&limit=1") else {
                return nil
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return nil
                }

                let decoded = try JSONDecoder().decode(GroceryWorkerSearchProductsResponse.self, from: data)
                guard let best = decoded.products.first,
                      let name = best.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return nil
                }

                return SimpleProduct(
                    barcode: barcode,
                    productName: name,
                    ingredientsList: best.detailsText,
                    quantityValue: nil,
                    imageURL: best.imageUrl.flatMap { URL(string: $0) }
                )
            } catch {
                print("[Scanner] Grocery worker search-by-barcode failed: \(error.localizedDescription)")
                return nil
            }
        }

        private func extractTextLines(from items: [RecognizedItem]) -> [String] {
            var out: [String] = []
            out.reserveCapacity(items.count * 2)
            for item in items {
                if case let .text(t) = item {
                    let raw = t.transcript
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { out.append(trimmed) }
                }
            }
            return out
        }

        /// Resolves the best product-name query from OCR lines, preferring the
        /// on-device model (iOS 26+) and falling back to the heuristic picker.
        /// Intended for user-initiated / single-shot use — never call per frame.
        private func resolveFrontLabelName(from lines: [String]) async -> String? {
            if let aiName = await LabelScanService.shared.bestProductName(from: lines),
               !aiName.isEmpty {
                return aiName
            }
            return inferFrontLabelName(from: lines)
        }

        /// Picks the most prominent (tallest) useful text as the product name.
        /// Brand marks on cans/bottles are the largest text in frame, so ranking
        /// by on-screen height beats a longest-string heuristic that would wrongly
        /// pick a tagline or legal line. Uses VisionKit's per-item bounds.
        private func mostProminentLabelName(from items: [RecognizedItem]) -> String? {
            var best: (name: String, height: CGFloat)?
            for item in items {
                guard case let .text(t) = item else { continue }
                let name = normalizeFrontLabelLine(t.transcript)
                guard isUsefulFrontLabelLine(name) else { continue }

                let b = item.bounds
                let height = max(abs(b.bottomLeft.y - b.topLeft.y),
                                 abs(b.bottomRight.y - b.topRight.y))
                if best == nil || height > best!.height {
                    best = (name, height)
                }
            }
            return best?.name
        }

        private func inferFrontLabelName(from lines: [String]) -> String? {
            let cleaned = lines
                .map { normalizeFrontLabelLine($0) }
                .filter { isUsefulFrontLabelLine($0) }

            guard !cleaned.isEmpty else { return nil }

            // Prefer the longest strong candidate near the top of the frame.
            if let best = cleaned
                .sorted(by: {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                })
                .first {
                return best
            }

            return nil
        }

        private func normalizeFrontLabelLine(_ line: String) -> String {
            line
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func isUsefulFrontLabelLine(_ line: String) -> Bool {
            guard !line.isEmpty else { return false }

            let lower = line.lowercased()
            let blockedTerms = [
                "energy", "kcal", "kj", "fat", "saturates", "carbohydrate", "carbohydrates",
                "carbs", "sugars", "protein", "salt", "fibre", "fiber", "ingredients",
                "nutrition", "per 100", "serving", "barcode", "scan", "recycle", "www.",
                "keep refrigerated", "best before", "use by"
            ]

            if blockedTerms.contains(where: { lower.contains($0) }) { return false }
            if lower.rangeOfCharacter(from: .decimalDigits) != nil { return false }
            if line.count < 3 || line.count > 60 { return false }

            let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return letterCount >= 3
        }

        /// Called by the Capture button to use the text already recognized in the live scanner.
        private func captureCurrentFrame() {
            let lines = recentVisibleTextLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                print("[Scanner] Capture pressed but no recognized text is available yet.")
                AudioServicesPlaySystemSound(SystemSoundID(1107))
                return
            }

            switch mode {
            case .nutrition:
                print("[Scanner] Manual capture triggered for nutrition mode.")
                if let label = parseNutritionLabel(from: lines) {
                    AudioServicesPlaySystemSound(SystemSoundID(1520))
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.parent.onNutritionScanned?(label)
                        self.parent.isShowing = false
                        self.stopScanning()
                    }
                } else {
                    print("[Scanner] Nutrition capture failed to parse enough data.")
                    AudioServicesPlaySystemSound(SystemSoundID(1107))
                }

            case .frontLabel:
                print("[Scanner] Manual capture triggered for front-label mode.")
                Task { [weak self] in
                    guard let self else { return }
                    guard let name = await self.resolveFrontLabelName(from: lines), !name.isEmpty else {
                        print("[Scanner] Front-label capture could not infer a product name.")
                        AudioServicesPlaySystemSound(SystemSoundID(1107))
                        return
                    }
                    AudioServicesPlaySystemSound(SystemSoundID(1520))
                    await MainActor.run {
                        self.lastFrontLabelName = name
                        self.lastFrontLabelLookupTime = CACurrentMediaTime()
                        self.parent.onFrontLabelDetected?(name)
                    }
                    self.fetchFrontLabelCandidate(query: name)
                }

            case .barcode:
                print("[Scanner] Capture pressed in barcode mode; using visible text as a fallback.")
                Task { [weak self] in
                    guard let self else { return }
                    guard let name = await self.resolveFrontLabelName(from: lines), !name.isEmpty else {
                        AudioServicesPlaySystemSound(SystemSoundID(1107))
                        return
                    }
                    AudioServicesPlaySystemSound(SystemSoundID(1520))
                    await MainActor.run {
                        self.lastFrontLabelName = name
                        self.parent.onFrontLabelDetected?(name)
                    }
                    self.fetchFrontLabelCandidate(query: name)
                }
            }
        }

        private func attemptNutritionParse(lines: [String]) {
            guard mode == .nutrition else { return }
            // Need enough signal to avoid false positives.
            let joined = lines.joined(separator: " ").lowercased()
            let hasNutritionSignal = joined.contains("energy") || joined.contains("kcal") || joined.contains("kj") ||
                                     joined.contains("fat") || joined.contains("protein") || joined.contains("carbo") ||
                                     joined.contains("salt") || joined.contains("sugars")
            guard hasNutritionSignal else { return }

            // De-dupe: if we see the same set of lines repeatedly, don't spam callbacks.
            let fingerprint = joined.prefix(240)
            let now = CACurrentMediaTime()
            if String(fingerprint) == lastCode, now - lastTime < 1.0 { return }
            lastCode = String(fingerprint)
            lastTime = now

            guard let label = parseNutritionLabel(from: lines) else { return }
            AudioServicesPlaySystemSound(SystemSoundID(1520))

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onNutritionScanned?(label)
                self.parent.isShowing = false
                self.stopScanning()
            }
        }

        private func parseNutritionLabel(from lines: [String]) -> NutritionLabel? {
            // Heuristic parser for common UK/EU labels.
            // Supports: Energy (kJ/kcal), Fat, Saturates, Carbohydrate, Sugars, Fibre, Protein, Salt.
            // Works best when lines include values like "Fat 3.2g" or "Energy 850kJ 200kcal".

            func number(_ s: String) -> Double? {
                // Accept commas as decimal separators, strip non-numeric (except dot/comma)
                let cleaned = s.replacingOccurrences(of: ",", with: ".")
                let allowed = cleaned.filter { ("0123456789.".contains($0)) }
                return Double(allowed)
            }

            func findValue(for keywords: [String], unit: String? = nil) -> Double? {
                for line in lines {
                    let l = line.lowercased()
                    guard keywords.contains(where: { l.contains($0) }) else { continue }

                    // Prefer the first numeric in the line.
                    // If unit is provided, try to find a number near that unit.
                    if let unit {
                        // Split by spaces and look for tokens ending with unit.
                        let tokens = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                        if let token = tokens.first(where: { $0.contains(unit) }), let v = number(token) { return v }
                    }

                    // Fallback: regex-like scan for numeric substrings
                    let comps = l.split(whereSeparator: { !("0123456789,.".contains($0)) })
                    if let first = comps.first(where: { !$0.isEmpty }), let v = number(String(first)) {
                        return v
                    }
                }
                return nil
            }

            // Require at least energy + one macro to consider it valid.
            let energyKj = findValue(for: ["energy"], unit: "kj")
            let energyKcal = findValue(for: ["energy"], unit: "kcal") ?? findValue(for: ["kcal"], unit: "kcal")

            let fat = findValue(for: ["fat"], unit: "g")
            let protein = findValue(for: ["protein"], unit: "g")
            let carbs = findValue(for: ["carbohydrate", "carbohydrates", "carbs"], unit: "g")

            let hasMinimum = (energyKj != nil || energyKcal != nil) && (fat != nil || protein != nil || carbs != nil)
            guard hasMinimum else { return nil }

            let saturates = findValue(for: ["saturates", "saturated"], unit: "g")
            let sugars = findValue(for: ["sugars", "sugar"], unit: "g")
            let fibre = findValue(for: ["fibre", "fiber"], unit: "g")
            let salt = findValue(for: ["salt"], unit: "g")

            var out = NutritionLabel(
                energyKcal: energyKcal,
                energyKj: energyKj,
                fat: fat,
                saturates: saturates,
                carbs: carbs,
                sugars: sugars,
                fibre: fibre,
                protein: protein,
                salt: salt,
                rawLines: lines
            )

            // Some labels use "sodium" instead of salt. If salt is missing but sodium exists, estimate salt = sodium * 2.5
            if out.salt == nil {
                if let sodium = findValue(for: ["sodium"], unit: "g") {
                    out.salt = sodium * 2.5
                }
            }

            return out
        }

        private struct GroceryWorkerSearchProductsResponse: Decodable {
            let products: [GroceryWorkerProduct]
        }

        private struct GroceryWorkerProduct: Decodable {
            let name: String?
            let detailsText: String?
            let imageUrl: String?
            let productUrl: String?
            let productID: String?
            let chain: String?
        }
        
        // ✅ New: Response for single product lookup by barcode
        private struct GroceryWorkerProductResponse: Decodable {
            let name: String
            let description: String?
            let quantity: Double?
            let imageURL: URL?
            let price: Double?
            let currency: String?
        }

        // MARK: - Helper UI
        private func showLabel(_ text: String) {
            guard let container = containerVC else { return }
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.view.centerYAnchor),
                label.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.85)
            ])
        }
    }
}

// MARK: - Supporting Types for Enhanced Barcode Scanner

/// Simple ProductProtocol implementation for fallback scenarios
private struct SimpleProduct: ProductProtocol {
    let barcode: String?
    let productName: String?
    let ingredientsList: String?
    let quantityValue: Int?
    let imageURL: URL?
    
    // Initialize with flexible types
    init(barcode: String?, productName: String?, ingredientsList: String?, quantityValue: Double?, imageURL: URL?) {
        self.barcode = barcode
        self.productName = productName
        self.ingredientsList = ingredientsList
        self.quantityValue = quantityValue.map { Int($0) }
        self.imageURL = imageURL
    }
}

// MARK: - Orientation bridging for Vision

private extension UIImage {
    /// Maps `UIImage.Orientation` to the `CGImagePropertyOrientation` Vision expects,
    /// so text/barcode recognition reads the photo the right way up.
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

