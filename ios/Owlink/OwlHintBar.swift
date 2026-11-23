import UIKit
import CedricCore

/// Cedric's hint, in his speech bubble (as on the Mac): the hint's title
/// and detail, "Fix it" when the hint carries a fix, and a close button.
/// One hint at a time; "Next" when there are more. The tail points at the
/// owl (`tailOnTop`, `tailAtLeft`); the editor places it with
/// `OwlPlacement.bubbleYDown`.
final class OwlHintBar: UIView {
    static let tail: CGFloat = 10
    static let maxWidth: CGFloat = 360
    private let shape = CAShapeLayer()
    private var rowTop: NSLayoutConstraint!
    private var rowBottom: NSLayoutConstraint!
    var tailOnTop = false { didSet { if oldValue != tailOnTop { updateTail() } } }
    var tailAtLeft = false { didSet { if oldValue != tailAtLeft { setNeedsLayout() } } }
    let title = UILabel()
    let detail = UILabel()
    let fix = UIButton(configuration: .borderedProminent())
    let ignore = UIButton(configuration: .bordered())
    let nextButton = UIButton(configuration: .bordered())
    let close = UIButton(type: .close)
    var onFix: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = UIColor.secondarySystemBackground.cgColor
        shape.strokeColor = UIColor.separator.cgColor
        shape.lineWidth = 0.5
        layer.addSublayer(shape)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityIdentifier = "owl.hint"

        title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        title.numberOfLines = 2
        title.accessibilityIdentifier = "owl.hint.title"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 3
        fix.configuration?.title = String(localized: "Fix it")
        fix.configuration?.buttonSize = .small
        fix.accessibilityIdentifier = "owl.hint.fix"
        ignore.configuration?.title = String(localized: "Ignore")
        ignore.configuration?.buttonSize = .small
        ignore.accessibilityLabel = String(localized: "Ignore this word")
        ignore.accessibilityIdentifier = "owl.hint.ignore"
        ignore.isHidden = true
        nextButton.configuration?.title = String(localized: "Next")
        nextButton.configuration?.buttonSize = .small
        fix.addAction(UIAction { [weak self] _ in self?.onFix?() }, for: .primaryActionTriggered)
        ignore.addAction(UIAction { [weak self] _ in self?.onIgnore?() }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .primaryActionTriggered)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        close.accessibilityIdentifier = "owl.hint.close"

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 2
        let buttons = UIStackView(arrangedSubviews: [nextButton, ignore, fix])
        buttons.spacing = 8
        let right = UIStackView(arrangedSubviews: [close, buttons])
        right.axis = .vertical
        right.alignment = .trailing
        right.spacing = 6
        let row = UIStackView(arrangedSubviews: [text, right])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        rowTop = row.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        rowBottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8 - Self.tail)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rowTop, rowBottom,
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTail() {
        rowTop.constant = 8 + (tailOnTop ? Self.tail : 0)
        rowBottom.constant = -8 - (tailOnTop ? 0 : Self.tail)
        setNeedsLayout()
    }

    /// Its size at most `width` wide (tail included).
    func fit(width: CGFloat) -> CGSize {
        let w = min(width, Self.maxWidth)
        let s = systemLayoutSizeFitting(CGSize(width: w, height: UIView.layoutFittingCompressedSize.height),
                                        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: w, height: ceil(s.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = Self.tail
        let body = CGRect(x: 0, y: tailOnTop ? t : 0, width: bounds.width, height: max(0, bounds.height - t))
        let path = UIBezierPath(roundedRect: body, cornerRadius: 14)
        // The tail, towards the owl.
        let tx = tailAtLeft ? body.minX + 34 : body.maxX - 34
        let tail = UIBezierPath()
        if tailOnTop {
            tail.move(to: CGPoint(x: tx - 9, y: body.minY + 1))
            tail.addLine(to: CGPoint(x: tx, y: 0))
            tail.addLine(to: CGPoint(x: tx + 9, y: body.minY + 1))
        } else {
            tail.move(to: CGPoint(x: tx - 9, y: body.maxY - 1))
            tail.addLine(to: CGPoint(x: tx, y: bounds.height))
            tail.addLine(to: CGPoint(x: tx + 9, y: body.maxY - 1))
        }
        tail.close()
        path.append(tail)
        shape.frame = bounds
        shape.path = path.cgPath
        layer.shadowPath = path.cgPath
    }

    private func updateColors() {
        shape.fillColor = UIColor.secondarySystemBackground.resolvedColor(with: traitCollection).cgColor
        shape.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    func show(_ hint: OwlHint, fixTitle: String?, ignoreTitle: String? = nil, more: Bool) {
        title.text = hint.title
        detail.text = hint.detail
        detail.isHidden = hint.detail?.isEmpty ?? true
        fix.isHidden = fixTitle == nil
        if let fixTitle { fix.configuration?.title = fixTitle }
        ignore.isHidden = ignoreTitle == nil
        if let ignoreTitle { ignore.configuration?.title = ignoreTitle }
        nextButton.isHidden = !more
        accessibilityLabel = String(localized: "Cedric: \(hint.title)")
    }
}

extension UIFont {
    func withWeight(_ w: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: w)
    }
}
