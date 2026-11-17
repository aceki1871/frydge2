import UIKit

/// One row of the expanded notification, laid out like a till receipt:
///
///     ◯   12 │ 🥚  Eggs                         $8.90
///
/// Tick circle on the left, the quantity, a hairline divider, then the product
/// photo (or emoji fallback) and name, with the price on the trailing edge.
/// Tapping the quantity/photo/name area opens the item in the app; tapping the
/// circle ticks it into the basket.
final class ItemCell: UITableViewCell {

    static let reuseID = "ItemCell"

    /// Shortest a row can be: tall enough for the 36pt thumbnail plus padding.
    static let minimumRowHeight: CGFloat = 54
    /// Vertical padding above and below the name label.
    static let verticalPadding: CGFloat = 9

    /// The height every row will lay out at for the given traits. Used by the
    /// controller to size the whole notification without estimating.
    static func rowHeight(for traits: UITraitCollection) -> CGFloat {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        return max(minimumRowHeight, ceil(lineHeight) + verticalPadding * 2)
    }

    private let tickButton = UIButton(type: .system)
    private let quantityLabel = UILabel()
    private let quantityDivider = UIView()
    private let thumbContainer = UIView()
    private let photoView = UIImageView()
    private let emojiLabel = UILabel()
    private let nameLabel = UILabel()
    private let priceLabel = UILabel()
    /// Invisible hit target over quantity + photo + name.
    private let detailsButton = UIButton(type: .custom)

    /// Called when the tick circle is tapped.
    var onTick: (() -> Void)?
    /// Called when the item name (or its photo/quantity) is tapped.
    var onOpenDetails: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear

        tickButton.translatesAutoresizingMaskIntoConstraints = false
        tickButton.addTarget(self, action: #selector(tickTapped), for: .touchUpInside)

        quantityLabel.translatesAutoresizingMaskIntoConstraints = false
        quantityLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        quantityLabel.adjustsFontForContentSizeCategory = true
        quantityLabel.textColor = .secondaryLabel
        quantityLabel.textAlignment = .right
        quantityLabel.numberOfLines = 1
        quantityLabel.setContentHuggingPriority(.required, for: .horizontal)
        quantityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        quantityDivider.translatesAutoresizingMaskIntoConstraints = false
        quantityDivider.backgroundColor = .separator

        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.layer.cornerRadius = 8
        thumbContainer.layer.masksToBounds = true
        thumbContainer.backgroundColor = .secondarySystemFill

        photoView.translatesAutoresizingMaskIntoConstraints = false
        photoView.contentMode = .scaleAspectFill
        photoView.isHidden = true

        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = .systemFont(ofSize: 20)
        emojiLabel.textAlignment = .center

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        priceLabel.translatesAutoresizingMaskIntoConstraints = false
        priceLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        priceLabel.adjustsFontForContentSizeCategory = true
        priceLabel.textColor = .secondaryLabel
        priceLabel.textAlignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.backgroundColor = .clear
        detailsButton.addTarget(self, action: #selector(detailsTapped), for: .touchUpInside)
        detailsButton.accessibilityLabel = "Show item details"

        thumbContainer.addSubview(photoView)
        thumbContainer.addSubview(emojiLabel)
        contentView.addSubview(tickButton)
        contentView.addSubview(quantityLabel)
        contentView.addSubview(quantityDivider)
        contentView.addSubview(thumbContainer)
        contentView.addSubview(nameLabel)
        contentView.addSubview(priceLabel)
        // Added last so it sits above the labels it covers.
        contentView.addSubview(detailsButton)

        NSLayoutConstraint.activate([
            tickButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tickButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            tickButton.widthAnchor.constraint(equalToConstant: 36),
            tickButton.heightAnchor.constraint(equalToConstant: 36),

            // "12" column: wide enough for three digits so names line up.
            quantityLabel.leadingAnchor.constraint(equalTo: tickButton.trailingAnchor, constant: 4),
            quantityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            quantityLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            // The "slight line" between the number and the item.
            quantityDivider.leadingAnchor.constraint(equalTo: quantityLabel.trailingAnchor, constant: 8),
            quantityDivider.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            quantityDivider.widthAnchor.constraint(equalToConstant: 1),
            quantityDivider.heightAnchor.constraint(equalToConstant: 26),

            thumbContainer.leadingAnchor.constraint(equalTo: quantityDivider.trailingAnchor, constant: 10),
            thumbContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbContainer.widthAnchor.constraint(equalToConstant: 36),
            thumbContainer.heightAnchor.constraint(equalToConstant: 36),

            photoView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            photoView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),
            photoView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),

            emojiLabel.centerXAnchor.constraint(equalTo: thumbContainer.centerXAnchor),
            emojiLabel.centerYAnchor.constraint(equalTo: thumbContainer.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // Let the row grow with Dynamic Type instead of overflowing the
            // fixed minimum; keeps the laid-out height equal to rowHeight(for:).
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Self.verticalPadding),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Self.verticalPadding),

            priceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            priceLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            priceLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            detailsButton.leadingAnchor.constraint(equalTo: quantityLabel.leadingAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: priceLabel.leadingAnchor),
            detailsButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            detailsButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumRowHeight)
        ])
    }

    @objc private func tickTapped() {
        onTick?()
    }

    @objc private func detailsTapped() {
        onOpenDetails?()
    }

    func configure(
        name: String,
        quantity: String?,
        emoji: String,
        trailing: String?,
        isTicked: Bool,
        showsTick: Bool,
        showsChevron: Bool = false,
        opensDetails: Bool = true
    ) {
        tickButton.isHidden = !showsTick
        accessoryType = showsChevron ? .disclosureIndicator : .none
        let symbol = isTicked ? "checkmark.circle.fill" : "circle"
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        tickButton.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        tickButton.tintColor = isTicked ? .systemGreen : .tertiaryLabel
        tickButton.accessibilityLabel = isTicked ? "Remove \(name) from basket" : "Put \(name) in basket"

        let attributes: [NSAttributedString.Key: Any] = isTicked
            ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: UIColor.secondaryLabel]
            : [.foregroundColor: UIColor.label]
        nameLabel.attributedText = NSAttributedString(string: name, attributes: attributes)

        // Quantity column only appears for shopping rows; recipe rows (expiry
        // reminders) collapse it so the name starts right after the circle.
        let qty = (quantity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        quantityLabel.text = qty
        quantityLabel.isHidden = qty.isEmpty
        quantityDivider.isHidden = qty.isEmpty
        quantityLabel.textColor = isTicked ? .tertiaryLabel : .secondaryLabel

        emojiLabel.text = emoji
        thumbContainer.alpha = isTicked ? 0.5 : 1
        priceLabel.text = trailing
        priceLabel.isHidden = (trailing ?? "").isEmpty
        detailsButton.isUserInteractionEnabled = opensDetails
        setPhoto(nil)
    }

    func setPhoto(_ image: UIImage?) {
        photoView.image = image
        photoView.isHidden = image == nil
        emojiLabel.isHidden = image != nil
    }

    // MARK: - Fly-to-basket support

    /// A throwaway copy of the thumbnail, positioned in `container`'s
    /// coordinates, for the controller to animate into the basket.
    func makeThumbnailGhost(in container: UIView) -> (view: UIView, frame: CGRect)? {
        guard let ghost = thumbContainer.snapshotView(afterScreenUpdates: false) else { return nil }
        let frame = thumbContainer.convert(thumbContainer.bounds, to: container)
        ghost.frame = frame
        ghost.layer.cornerRadius = thumbContainer.layer.cornerRadius
        ghost.layer.masksToBounds = true
        return (ghost, frame)
    }
}
