import UIKit
import UserNotifications
import UserNotificationsUI

/// One entry of the expanded notification list.
private struct NotifItem {
    let id: String
    let name: String
    let fullName: String
    let emoji: String
    /// "12", "2 kg" — shown in the quantity column of shopping rows.
    let quantity: String?
    /// Right-aligned secondary text: a price for shopping rows, the fridge
    /// match for recipe rows.
    let trailing: String?
    let imageURL: URL?
    /// Set on "use it up" recipe rows; tapping opens this recipe in the app.
    var recipeID: String? = nil
}

/// Store identity shown at the top of the store-arrival notification.
private struct StoreHeader {
    /// Brand ("Pak’nSave", "Woolworths").
    let brand: String
    /// Branch / suburb ("Sylvia Park"), empty when the name is brand only.
    let branch: String
    /// Street address line from the store directory, may be empty.
    let address: String
    /// Asset name in StoreLogos.xcassets, nil for unknown brands.
    let logoAssetName: String?

    /// Splits "Pak’nSave Sylvia Park" into brand + branch using the brands the
    /// app knows about; unknown names keep the first word as the brand.
    static func parse(storeName: String, address: String, logoOverride: String?) -> StoreHeader {
        let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
            .replacingOccurrences(of: "’", with: "'")

        // Longest names first so "Waitrose & Partners" wins over "Waitrose".
        let knownBrands: [(match: String, display: String, asset: String)] = [
            ("pak'nsave", "Pak’nSave", "paknsave"),
            ("pak n save", "Pak’nSave", "paknsave"),
            ("paknsave", "Pak’nSave", "paknsave"),
            ("woolworths", "Woolworths", "woolworths"),
            ("countdown", "Countdown", "countdown"),
            ("new world", "New World", "newworld"),
            ("four square", "Four Square", "foursquare"),
            ("waitrose & partners", "Waitrose & Partners", "waitrose"),
            ("waitrose", "Waitrose", "waitrose"),
            ("sainsbury's local", "Sainsbury’s Local", "sainsburys"),
            ("sainsbury's", "Sainsbury’s", "sainsburys"),
            ("sainsburys", "Sainsbury’s", "sainsburys"),
            ("tesco extra", "Tesco Extra", "tesco"),
            ("tesco", "Tesco", "tesco"),
            ("co-op food", "Co-op Food", "coop"),
            ("co-op", "Co-op", "coop"),
            ("coop", "Co-op", "coop"),
            ("morrisons", "Morrisons", "morrisons"),
            ("asda", "Asda", "asda"),
            ("aldi", "Aldi", "aldi")
        ]

        for brand in knownBrands where folded.hasPrefix(brand.match) {
            let rest = trimmed.dropFirst(brand.match.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return StoreHeader(
                brand: brand.display,
                branch: rest,
                address: address,
                logoAssetName: logoOverride ?? brand.asset
            )
        }

        // Unknown brand: first word is the brand, the rest is the branch.
        let words = trimmed.split(separator: " ").map(String.init)
        let brand = words.first ?? (trimmed.isEmpty ? "Shopping" : trimmed)
        let branch = words.dropFirst().joined(separator: " ")
        return StoreHeader(brand: brand, branch: branch, address: address, logoAssetName: logoOverride)
    }
}

/// Renders the expanded (long-press) view for the store-arrival shopping list
/// notification and the expiry reminder.
///
/// Shopping list layout, top to bottom: store logo (with a basket + progress
/// pill on the right), the store brand and its branch/address, a hairline,
/// then one receipt-style row per item (`ItemCell`). Ticking a row animates
/// its thumbnail into the basket and persists the tick to the shared app
/// group; the main app moves those items into the fridge on its next
/// activation. Tapping an item's name parks the item in the app group and
/// fires the default action so the app opens its detail sheet.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    @IBOutlet weak var tableView: UITableView!

    // Header
    private let headerStack = UIStackView()
    private let logoRow = UIStackView()
    private let logoView = UIImageView()
    private let basketPill = UIView()
    private let basketIcon = UIImageView()
    private let basketCountLabel = UILabel()
    private let summaryContainer = UIStackView()
    private let summaryTitleLabel = UILabel()
    private let summaryCountBadge = UILabel()
    private let storeNameLabel = UILabel()
    private let storeLocationLabel = UILabel()
    private let bodyLabel = UILabel()
    private let headerHairline = UIView()

    // Expiry card: photo-or-emoji badge, name with a days-left pill, then
    // the expiry date and amount. Shown instead of the title/badge pair.
    private let itemCard = UIStackView()
    private let itemBadge = UIView()
    private let itemEmojiLabel = UILabel()
    private let itemPhotoView = UIImageView()
    private let itemNameLabel = UILabel()
    private let statusPill = UILabel()
    private let itemDetailLabel = UILabel()
    /// "USE IT UP · 3 RECIPES" caption above the recipe rows.
    private let useItUpLabel = UILabel()

    private let headerTopInset: CGFloat = 12
    private let headerBottomInset: CGFloat = 4
    private let horizontalInset: CGFloat = 16

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let tickedItemsKey = "notificationTickedItems_v1"
    /// Mirrors FrydgeManager.ExpiryNotificationKeys.tappedRecipeID in the app.
    private let tappedRecipeIDKey = "notificationOpenRecipeID_v1"
    /// Mirrors ShoppingNotificationKeys.tappedItem in the app: the shopping
    /// item whose name was tapped, as `["id", "name", "fullName", "store"]`.
    private let tappedShoppingItemKey = "notificationOpenShoppingItem_v1"

    private let shoppingListCategory = "SHOPPING_LIST_CATEGORY"
    private let expiryReminderCategory = "EXPIRY_REMINDER"

    private var items: [NotifItem] = []
    private var allowsTicking = false
    private var tickedIDs: Set<String> = []
    private var imageCache: [String: UIImage] = [:]
    private var storeName = ""
    private var isShoppingList = false

    override func viewDidLoad() {
        super.viewDidLoad()

        guard tableView != nil else {
            print("[ERROR] TableView outlet is nil. Ensure it is properly connected in the storyboard.")
            return
        }

        configureHeaderViews()

        view.addSubview(headerStack)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontalInset),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -horizontalInset),
            summaryCountBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            summaryCountBadge.heightAnchor.constraint(equalToConstant: 24),
            logoView.widthAnchor.constraint(equalToConstant: 44),
            logoView.heightAnchor.constraint(equalToConstant: 44),
            basketIcon.widthAnchor.constraint(equalToConstant: 18),
            basketIcon.heightAnchor.constraint(equalToConstant: 18),
            headerHairline.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1))
        ])

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = ItemCell.minimumRowHeight
        tableView.alwaysBounceVertical = true
        // Don't let the system add safe-area padding inside the list; every
        // point of the expanded notification should go to rows.
        tableView.contentInsetAdjustmentBehavior = .never
        // The faint rule above each item, aligned with the full row.
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = UIColor.separator.withAlphaComponent(0.6)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        if tableView.superview === self.view {
            NSLayoutConstraint.activate([
                tableView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: headerBottomInset),
                tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        tableView.register(ItemCell.self, forCellReuseIdentifier: ItemCell.reuseID)

        tableView.isHidden = true
        summaryContainer.isHidden = false

        updatePreferredContentSize()
    }

    private func configureHeaderViews() {
        // Logo row: brand mark on the left, basket progress pill on the right.
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.contentMode = .scaleAspectFill
        logoView.layer.cornerRadius = 10
        logoView.layer.masksToBounds = true
        logoView.backgroundColor = .secondarySystemFill
        logoView.tintColor = .secondaryLabel

        basketIcon.translatesAutoresizingMaskIntoConstraints = false
        basketIcon.image = UIImage(systemName: "basket.fill")
        basketIcon.contentMode = .scaleAspectFit
        basketIcon.tintColor = .systemGreen

        basketCountLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        basketCountLabel.adjustsFontForContentSizeCategory = true
        basketCountLabel.textColor = .label

        let pillStack = UIStackView(arrangedSubviews: [basketIcon, basketCountLabel])
        pillStack.axis = .horizontal
        pillStack.alignment = .center
        pillStack.spacing = 6
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        basketPill.translatesAutoresizingMaskIntoConstraints = false
        basketPill.backgroundColor = .secondarySystemFill
        basketPill.layer.cornerRadius = 15
        basketPill.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: basketPill.leadingAnchor, constant: 10),
            pillStack.trailingAnchor.constraint(equalTo: basketPill.trailingAnchor, constant: -12),
            pillStack.topAnchor.constraint(equalTo: basketPill.topAnchor, constant: 6),
            pillStack.bottomAnchor.constraint(equalTo: basketPill.bottomAnchor, constant: -6),
            basketPill.heightAnchor.constraint(equalToConstant: 30)
        ])

        let logoSpacer = UIView()
        logoSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        logoRow.axis = .horizontal
        logoRow.alignment = .center
        logoRow.spacing = 8
        logoRow.addArrangedSubview(logoView)
        logoRow.addArrangedSubview(logoSpacer)
        logoRow.addArrangedSubview(basketPill)
        logoRow.isHidden = true

        // Title + count badge, used by the expiry reminder and generic pushes.
        summaryContainer.axis = .horizontal
        summaryContainer.alignment = .center
        summaryContainer.distribution = .fill
        summaryContainer.spacing = 10
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false

        summaryTitleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        summaryTitleLabel.adjustsFontForContentSizeCategory = true
        summaryTitleLabel.textColor = .label
        summaryTitleLabel.numberOfLines = 2

        summaryCountBadge.font = UIFont.preferredFont(forTextStyle: .subheadline)
        summaryCountBadge.adjustsFontForContentSizeCategory = true
        summaryCountBadge.textColor = .white
        summaryCountBadge.backgroundColor = .systemBlue
        summaryCountBadge.layer.cornerRadius = 12
        summaryCountBadge.layer.masksToBounds = true
        summaryCountBadge.textAlignment = .center
        summaryCountBadge.setContentHuggingPriority(.required, for: .horizontal)

        summaryContainer.addArrangedSubview(summaryTitleLabel)
        summaryContainer.addArrangedSubview(summaryCountBadge)

        // Store brand + branch/address, shopping list only.
        storeNameLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        storeNameLabel.adjustsFontForContentSizeCategory = true
        storeNameLabel.textColor = .label
        storeNameLabel.numberOfLines = 1
        storeNameLabel.isHidden = true

        storeLocationLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        storeLocationLabel.adjustsFontForContentSizeCategory = true
        storeLocationLabel.textColor = .secondaryLabel
        storeLocationLabel.numberOfLines = 1
        storeLocationLabel.isHidden = true

        // Full notification body for categories that have no list to show
        // (shared fridge / shared shopping list pushes). The system's default
        // content is hidden for this extension, so without this the body text
        // would never be visible in the expanded view.
        bodyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.isHidden = true

        headerHairline.backgroundColor = .separator
        headerHairline.isHidden = true

        configureExpiryCardViews()

        headerStack.axis = .vertical
        headerStack.alignment = .fill
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(logoRow)
        headerStack.addArrangedSubview(itemCard)
        headerStack.addArrangedSubview(summaryContainer)
        headerStack.addArrangedSubview(storeNameLabel)
        headerStack.addArrangedSubview(storeLocationLabel)
        headerStack.addArrangedSubview(bodyLabel)
        headerStack.addArrangedSubview(headerHairline)
        headerStack.addArrangedSubview(useItUpLabel)
        // A touch more air between the logo and the store name, and between
        // the address and the hairline, so the three areas read separately.
        headerStack.setCustomSpacing(10, after: logoRow)
        headerStack.setCustomSpacing(10, after: itemCard)
        headerStack.setCustomSpacing(2, after: storeNameLabel)
        headerStack.setCustomSpacing(10, after: storeLocationLabel)
        headerStack.setCustomSpacing(8, after: headerHairline)
    }

    /// Builds the expiry card. Hidden until an expiry reminder is shown.
    private func configureExpiryCardViews() {
        itemBadge.translatesAutoresizingMaskIntoConstraints = false
        itemBadge.backgroundColor = .secondarySystemFill
        itemBadge.layer.cornerRadius = 14
        itemBadge.layer.masksToBounds = true

        itemEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
        itemEmojiLabel.font = UIFont.systemFont(ofSize: 30)
        itemEmojiLabel.textAlignment = .center
        itemEmojiLabel.adjustsFontSizeToFitWidth = true

        itemPhotoView.translatesAutoresizingMaskIntoConstraints = false
        itemPhotoView.contentMode = .scaleAspectFill
        itemPhotoView.isHidden = true

        itemBadge.addSubview(itemEmojiLabel)
        itemBadge.addSubview(itemPhotoView)
        NSLayoutConstraint.activate([
            itemBadge.widthAnchor.constraint(equalToConstant: 56),
            itemBadge.heightAnchor.constraint(equalToConstant: 56),
            itemEmojiLabel.leadingAnchor.constraint(equalTo: itemBadge.leadingAnchor),
            itemEmojiLabel.trailingAnchor.constraint(equalTo: itemBadge.trailingAnchor),
            itemEmojiLabel.topAnchor.constraint(equalTo: itemBadge.topAnchor),
            itemEmojiLabel.bottomAnchor.constraint(equalTo: itemBadge.bottomAnchor),
            itemPhotoView.leadingAnchor.constraint(equalTo: itemBadge.leadingAnchor),
            itemPhotoView.trailingAnchor.constraint(equalTo: itemBadge.trailingAnchor),
            itemPhotoView.topAnchor.constraint(equalTo: itemBadge.topAnchor),
            itemPhotoView.bottomAnchor.constraint(equalTo: itemBadge.bottomAnchor)
        ])

        itemNameLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        itemNameLabel.adjustsFontForContentSizeCategory = true
        itemNameLabel.textColor = .label
        itemNameLabel.numberOfLines = 2
        itemNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusPill.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        statusPill.adjustsFontForContentSizeCategory = true
        statusPill.textAlignment = .center
        statusPill.layer.cornerRadius = 11
        statusPill.layer.masksToBounds = true
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusPill.heightAnchor.constraint(equalToConstant: 22).isActive = true

        itemDetailLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        itemDetailLabel.adjustsFontForContentSizeCategory = true
        itemDetailLabel.textColor = .secondaryLabel
        itemDetailLabel.numberOfLines = 1

        let nameRow = UIStackView(arrangedSubviews: [itemNameLabel, statusPill])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 8

        let textStack = UIStackView(arrangedSubviews: [nameRow, itemDetailLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3

        itemCard.axis = .horizontal
        itemCard.alignment = .center
        itemCard.spacing = 12
        itemCard.addArrangedSubview(itemBadge)
        itemCard.addArrangedSubview(textStack)
        itemCard.isHidden = true

        useItUpLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .semibold
        )
        useItUpLabel.adjustsFontForContentSizeCategory = true
        useItUpLabel.textColor = .secondaryLabel
        useItUpLabel.isHidden = true
    }

    /// "2 days left" / "Expires today" / "Expired yesterday", coloured by
    /// urgency, worked out when the card is shown so it stays right however
    /// long the notification has sat in the tray.
    private struct ExpiryStatus {
        let text: String
        let color: UIColor
        let isPast: Bool
    }

    private static func expiryStatus(expiryTimestamp: Double?) -> ExpiryStatus {
        guard let expiryTimestamp else {
            return ExpiryStatus(text: "Expiring soon", color: .systemOrange, isPast: false)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expiryDay = calendar.startOfDay(for: Date(timeIntervalSince1970: expiryTimestamp))
        let days = calendar.dateComponents([.day], from: today, to: expiryDay).day ?? 0
        switch days {
        case ..<(-1): return ExpiryStatus(text: "Expired \(-days) days ago", color: .systemRed, isPast: true)
        case -1:      return ExpiryStatus(text: "Expired yesterday", color: .systemRed, isPast: true)
        case 0:       return ExpiryStatus(text: "Expires today", color: .systemOrange, isPast: false)
        case 1:       return ExpiryStatus(text: "1 day left", color: .systemOrange, isPast: false)
        case 2...3:   return ExpiryStatus(text: "\(days) days left", color: .systemOrange, isPast: false)
        default:      return ExpiryStatus(text: "\(days) days left", color: .systemGreen, isPast: false)
        }
    }

    private func updatePreferredContentSize() {
        let width = max(view.bounds.width, 320)
        let showingTable = !tableView.isHidden && !items.isEmpty

        // Measure the header rather than assuming a fixed height, so Dynamic
        // Type and long bodies don't get clipped and short headers don't
        // waste space.
        let headerFit = CGSize(width: width - horizontalInset * 2, height: UIView.layoutFittingCompressedSize.height)
        let headerHeight = headerStack.systemLayoutSizeFitting(
            headerFit,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        // Ask for every row at once — no row cap. The system clamps the
        // expanded notification to the space actually available on screen,
        // so a long list fills the screen and scrolls, while a short list
        // sizes to fit exactly.
        let rowHeight = ItemCell.rowHeight(for: traitCollection)
        let tableHeight = showingTable ? CGFloat(items.count) * rowHeight : 0

        let total = headerTopInset + headerHeight + headerBottomInset + tableHeight + (showingTable ? 0 : headerTopInset)
        let screenHeight = view.window?.windowScene?.screen.bounds.height ?? 1_000
        let size = CGSize(width: width, height: min(total, screenHeight))
        // viewDidLayoutSubviews calls this; only publish real changes so the
        // system isn't asked to re-layout for an identical size.
        if size != preferredContentSize {
            preferredContentSize = size
        }
    }

    /// Shows the notification body under the title for categories that don't
    /// render a list, so none of the text is lost.
    private func showBody(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.text = trimmed
        bodyLabel.isHidden = trimmed.isEmpty
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content

        // Reset the category-specific chrome; each category turns on what it needs.
        isShoppingList = false
        logoRow.isHidden = true
        storeNameLabel.isHidden = true
        storeLocationLabel.isHidden = true
        headerHairline.isHidden = true
        itemCard.isHidden = true
        useItUpLabel.isHidden = true
        summaryContainer.isHidden = false

        switch content.categoryIdentifier {
        case shoppingListCategory:
            configureForShoppingList(content: content)
        case expiryReminderCategory:
            configureForExpiry(content: content)
        default:
            summaryTitleLabel.text = content.title.isEmpty ? "Update" : content.title
            summaryCountBadge.text = ""
            summaryCountBadge.isHidden = true
            tableView.isHidden = true
            items = []
            showBody(content.body)
        }

        tableView.reloadData()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updatePreferredContentSize()
        // Re-measure once the system has given us a window; the first pass
        // can run before the final width is known.
        DispatchQueue.main.async { self.updatePreferredContentSize() }
    }

    private func configureForShoppingList(content: UNNotificationContent) {
        let userInfo = content.userInfo
        let payload = userInfo["shoppingItems"] as? [[String: String]] ?? []
        items = payload.compactMap { entry in
            let name = entry["name"] ?? ""
            guard !name.isEmpty else { return nil }
            let urlString = entry["imageURL"] ?? ""
            return NotifItem(
                id: (entry["id"]?.isEmpty == false) ? entry["id"]! : name,
                name: name,
                fullName: entry["fullName"] ?? name,
                emoji: entry["emoji"] ?? "🛒",
                quantity: Self.quantityText(quantity: entry["quantity"], unit: entry["unit"]),
                trailing: (entry["price"]?.isEmpty == false) ? entry["price"] : nil,
                imageURL: urlString.isEmpty ? nil : URL(string: urlString)
            )
        }
        isShoppingList = true
        allowsTicking = true
        tickedIDs = Set(loadTickedEntries().compactMap { $0["id"] })
        // The rows *are* the body here; the collapsed body text ("…hold to
        // tick items off") would only steal space from them.
        bodyLabel.isHidden = true

        // Store identity. Prefer the structured keys; fall back to pulling the
        // store out of the title ("🛒 You're at Pak’nSave Sylvia Park").
        storeName = (userInfo["storeName"] as? String)
            ?? (userInfo["store"] as? String)
            ?? content.title.replacingOccurrences(of: "🛒 You're at ", with: "")
        let header = StoreHeader.parse(
            storeName: storeName,
            address: (userInfo["storeLocation"] as? String) ?? "",
            logoOverride: (userInfo["storeLogo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )

        if let asset = header.logoAssetName, let image = UIImage(named: asset) {
            logoView.image = image
            logoView.contentMode = .scaleAspectFill
            logoView.backgroundColor = .clear
        } else {
            logoView.image = UIImage(systemName: "cart.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
            logoView.contentMode = .center
            logoView.backgroundColor = .secondarySystemFill
        }

        storeNameLabel.text = header.brand
        let locationBits = [header.branch, header.address].filter { !$0.isEmpty }
        storeLocationLabel.text = locationBits.joined(separator: " · ")
        storeLocationLabel.isHidden = locationBits.isEmpty

        logoRow.isHidden = false
        storeNameLabel.isHidden = false
        headerHairline.isHidden = false
        // The title/badge pair is replaced by the logo + store block here.
        summaryContainer.isHidden = true
        summaryCountBadge.isHidden = true

        updateBasketPill()
        tableView.isHidden = items.isEmpty
    }

    /// "12" for 12 ea, "2 kg" for weights; nil when the payload carries none.
    private static func quantityText(quantity: String?, unit: String?) -> String? {
        let qty = (quantity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !qty.isEmpty else { return nil }
        if unit.isEmpty || unit.lowercased() == "ea" || unit.lowercased() == "each" { return qty }
        return "\(qty) \(unit)"
    }

    /// Basket pill: "3 / 12" once shopping has started, "12 items" before.
    private func updateBasketPill() {
        let total = items.count
        let got = items.filter { tickedIDs.contains($0.id) }.count
        if got == 0 {
            basketCountLabel.text = "\(total) item\(total == 1 ? "" : "s")"
        } else {
            basketCountLabel.text = "\(got) / \(total)"
        }
        basketIcon.tintColor = got == total && total > 0 ? .systemGreen : .label
        basketCountLabel.textColor = got == total && total > 0 ? .systemGreen : .label
    }

    private func configureForExpiry(content: UNNotificationContent) {
        let userInfo = content.userInfo
        allowsTicking = false

        // The item card replaces the title/badge pair.
        summaryContainer.isHidden = true
        summaryCountBadge.isHidden = true

        let rawName = (userInfo["name"] as? String)
            ?? (userInfo["expiringItems"] as? [String])?.first
            ?? ""
        itemNameLabel.text = rawName.isEmpty ? "Food expiring soon" : rawName.localizedCapitalized

        // Photo when the item has one (attached by the app), emoji otherwise.
        itemEmojiLabel.text = (userInfo["itemEmoji"] as? String) ?? "⏰"
        itemEmojiLabel.isHidden = false
        itemPhotoView.image = nil
        itemPhotoView.isHidden = true
        if let attachment = content.attachments.first(where: { $0.identifier == "itemPhoto" }) ?? content.attachments.first,
           attachment.url.startAccessingSecurityScopedResource() {
            defer { attachment.url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: attachment.url),
               let image = Self.downsampledImage(from: data, maxPixelSize: 224) {
                itemPhotoView.image = image
                itemPhotoView.isHidden = false
                itemEmojiLabel.isHidden = true
            }
        }

        let status = Self.expiryStatus(expiryTimestamp: userInfo["expiry"] as? Double)
        statusPill.text = "  \(status.text)  "
        statusPill.textColor = status.color
        statusPill.backgroundColor = status.color.withAlphaComponent(0.16)

        var details: [String] = []
        if let expiryText = userInfo["expiryText"] as? String, !expiryText.isEmpty {
            details.append(status.isPast ? "Best before \(expiryText)" : "Expires \(expiryText)")
        }
        if let quantity = userInfo["quantityText"] as? String, !quantity.isEmpty {
            details.append("\(quantity) in your frydge")
        }
        itemDetailLabel.text = details.joined(separator: " · ")
        itemDetailLabel.isHidden = details.isEmpty

        itemCard.isHidden = false
        headerHairline.isHidden = false

        // Recipes that use the expiring item, ranked by fridge match when the
        // reminder was scheduled (FrydgeManager.expirySuggestions). These are
        // the point of the expanded view, so they take the list.
        let recipes = (userInfo["suggestedRecipes"] as? [[String: String]] ?? []).compactMap { entry -> NotifItem? in
            guard let id = entry["id"], !id.isEmpty,
                  let name = entry["name"], !name.isEmpty else { return nil }
            let urlString = entry["imageURL"] ?? ""
            let match = entry["match"] ?? ""
            return NotifItem(
                id: "recipe:" + id,
                name: name,
                fullName: name,
                emoji: "🍳",
                quantity: nil,
                trailing: match.isEmpty ? nil : "\(match) match",
                imageURL: urlString.isEmpty ? nil : URL(string: urlString),
                recipeID: id
            )
        }

        if !recipes.isEmpty {
            items = recipes
            useItUpLabel.text = "USE IT UP · \(recipes.count) RECIPE\(recipes.count == 1 ? "" : "S") · TAP ONE TO COOK"
            useItUpLabel.isHidden = false
            bodyLabel.isHidden = true
            tableView.isHidden = false
            return
        }

        // No recipes use it: the card alone, with a one-line nudge.
        items = []
        tableView.isHidden = true
        showBody(status.isPast
                 ? "No saved recipes use this. Check it's still good, or mark it used."
                 : "No saved recipes use this yet. Cook it, freeze it, or mark it used.")
    }

    func didReceive(_ response: UNNotificationResponse,
                    completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        // The extension can't mark items used, add to the list or snooze on
        // its own — the app handles every action button. Forward them all;
        // swallowing them here left the buttons doing nothing from the
        // expanded view.
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            completion(.dismiss)
        default:
            completion(.dismissAndForwardAction)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    // MARK: - Opening in the app

    /// The extension can't navigate the app itself, so park the choice in
    /// the app group and fire the notification's default action; the app
    /// reads the key when it handles that tap and opens the recipe.
    private func openRecipe(_ recipeID: String) {
        UserDefaults(suiteName: appGroupName)?.set(recipeID, forKey: tappedRecipeIDKey)
        extensionContext?.performNotificationDefaultAction()
    }

    /// Same hand-off for a shopping item: the app opens its detail sheet
    /// (nutrition, recipes from the basket, what else to grab in this store).
    private func openItemDetails(_ item: NotifItem) {
        let entry: [String: String] = [
            "id": item.id,
            "name": item.name,
            "fullName": item.fullName,
            "store": storeName
        ]
        UserDefaults(suiteName: appGroupName)?.set(entry, forKey: tappedShoppingItemKey)
        extensionContext?.performNotificationDefaultAction()
    }

    // MARK: - Ticking

    private func toggleTick(for item: NotifItem) {
        let nowTicked = !tickedIDs.contains(item.id)
        if nowTicked {
            tickedIDs.insert(item.id)
        } else {
            tickedIDs.remove(item.id)
        }
        persistTicks()

        guard let row = items.firstIndex(where: { $0.id == item.id }) else { return }
        let indexPath = IndexPath(row: row, section: 0)

        if nowTicked, isShoppingList, let cell = tableView.cellForRow(at: indexPath) as? ItemCell {
            flyIntoBasket(from: cell)
        } else if isShoppingList {
            updateBasketPill()
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    /// Lifts a copy of the row's thumbnail and arcs it into the basket pill,
    /// shrinking and fading as it lands; the basket then gives a little bounce
    /// and the count ticks over.
    private func flyIntoBasket(from cell: ItemCell) {
        guard let ghost = cell.makeThumbnailGhost(in: view) else {
            updateBasketPill()
            return
        }
        view.addSubview(ghost.view)

        let start = CGPoint(x: ghost.frame.midX, y: ghost.frame.midY)
        let target = basketIcon.convert(CGPoint(x: basketIcon.bounds.midX, y: basketIcon.bounds.midY), to: view)

        // Arc up and across so the item visibly "leaves" the list.
        let path = UIBezierPath()
        path.move(to: start)
        let control = CGPoint(x: (start.x + target.x) / 2, y: min(start.y, target.y) - 70)
        path.addQuadCurve(to: target, controlPoint: control)

        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path.cgPath
        move.calculationMode = .paced

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.25

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.1
        fade.beginTime = 0.3

        let group = CAAnimationGroup()
        group.animations = [move, shrink, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            ghost.view.removeFromSuperview()
            self?.bounceBasket()
        }
        ghost.view.layer.add(group, forKey: "flyIntoBasket")
        CATransaction.commit()
    }

    private func bounceBasket() {
        updateBasketPill()
        basketPill.transform = .identity
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            self.basketPill.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
        } completion: { _ in
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.8) {
                self.basketPill.transform = .identity
            }
        }
    }

    private func loadTickedEntries() -> [[String: String]] {
        UserDefaults(suiteName: appGroupName)?
            .array(forKey: tickedItemsKey) as? [[String: String]] ?? []
    }

    private func persistTicks() {
        guard let ud = UserDefaults(suiteName: appGroupName) else { return }

        // Keep entries from other notifications; replace the ones we own.
        let ownIDs = Set(items.map { $0.id })
        var entries = loadTickedEntries().filter { entry in
            guard let id = entry["id"] else { return false }
            return !ownIDs.contains(id)
        }

        for item in items where tickedIDs.contains(item.id) {
            entries.append(["id": item.id, "name": item.name, "fullName": item.fullName])
        }

        ud.set(entries, forKey: tickedItemsKey)
    }

    // MARK: - Photos

    private func loadImage(for item: NotifItem, at indexPath: IndexPath) {
        guard let url = item.imageURL else { return }

        if let cached = imageCache[item.id] {
            (tableView.cellForRow(at: indexPath) as? ItemCell)?.setPhoto(cached)
            return
        }

        // Notification content extensions run under a tight memory ceiling;
        // decoding a full-size product photo for a 36 pt thumbnail can get
        // the extension killed, which the user sees as "no photos". Decode a
        // downsampled bitmap straight from the bytes instead.
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = Self.downsampledImage(from: data, maxPixelSize: 144) else { return }
            DispatchQueue.main.async {
                self.imageCache[item.id] = image
                // Only touch the cell if that row is still showing this item.
                if let row = self.items.firstIndex(where: { $0.id == item.id }),
                   let cell = self.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? ItemCell {
                    cell.setPhoto(image)
                }
            }
        }.resume()
    }

    /// ImageIO downsampling: never materialises the full-resolution bitmap.
    private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

extension NotificationViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView.isHidden ? 0 : items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ItemCell.reuseID, for: indexPath) as? ItemCell else {
            return UITableViewCell()
        }

        let item = items[indexPath.row]
        cell.configure(
            name: item.name,
            quantity: item.quantity,
            emoji: item.emoji,
            trailing: item.trailing,
            isTicked: tickedIDs.contains(item.id),
            showsTick: allowsTicking,
            showsChevron: item.recipeID != nil,
            // Recipe rows open via row selection; shopping rows open from
            // the name so the rest of the row can stay a tick target.
            opensDetails: isShoppingList
        )
        cell.onTick = { [weak self] in
            self?.toggleTick(for: item)
        }
        cell.onOpenDetails = { [weak self] in
            self?.openItemDetails(item)
        }
        if let cached = imageCache[item.id] {
            cell.setPhoto(cached)
        } else {
            loadImage(for: item, at: indexPath)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let item = items[indexPath.row]
        if let recipeID = item.recipeID {
            openRecipe(recipeID)
            return
        }
        guard allowsTicking else { return }
        toggleTick(for: item)
    }
}
