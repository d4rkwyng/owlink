import UIKit
import CedricCore

private final class DailyGoalRing: UIView {
    var progress: CGFloat = 0 { didSet { setNeedsDisplay() } }

    override var intrinsicContentSize: CGSize { CGSize(width: 40, height: 40) }

    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 3
        let track = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2,
                                 endAngle: 3 * .pi / 2, clockwise: true)
        track.lineWidth = 5
        UIColor.tertiarySystemFill.setStroke()
        track.stroke()
        let arc = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2,
                               endAngle: -.pi / 2 + 2 * .pi * progress, clockwise: true)
        arc.lineWidth = 5
        tintColor.setStroke()
        arc.stroke()
    }
}

func localizedWordCount(_ count: Int) -> String {
    let noun = count == 1 ? String(localized: "word") : String(localized: "words")
    return "\(count.formatted()) \(noun)"
}

/// A self-contained statistics sheet. Call `update(text:selection:)` when the
/// editor changes; the file path identifies the persisted goal.
@MainActor final class StatisticsViewController: UIViewController {
    private static let goalsKey = "statistics.fileWordGoals"

    private let filePath: String
    private let defaults: UserDefaults
    private var text: String
    private var selection: NSRange
    private var documentLines: Int?
    private var generation = 0
    private var documentCounts: TextCounts?
    private var isCalculating = false
    private var goal: Int?
    private var goalTimer: Timer?
    private var goalIsDirty = false
    private var hasDisplayedCounts = false

    private let documentValues = (0..<4).map { _ in UILabel() }
    private let selectionValues = (0..<4).map { _ in UILabel() }
    private let selectionSection = UIStackView()
    private let goalField = UITextField()
    private let goalError = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let dailyField = UITextField()
    private let dailyError = UILabel()
    private let dailyProgress = DailyGoalRing()
    private let dailyLabel = UILabel()
    private let dailyWords: DailyWordCounter
    private var dailyRefreshTimer: Timer?

    init(text: String, selection: NSRange, filePath: String, documentLines: Int? = nil, defaults: UserDefaults = .standard,
         dailyWords: DailyWordCounter = .shared) {
        self.text = text
        self.selection = selection
        self.documentLines = documentLines
        self.filePath = filePath
        self.defaults = defaults
        self.dailyWords = dailyWords
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Statistics")
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "stats.popover"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Done"), style: .done, target: self, action: #selector(dismissSheet))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "stats.done"

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])

        addSection(String(localized: "Document"), values: documentValues, to: stack)
        selectionSection.axis = .vertical
        selectionSection.spacing = 12
        addSection(String(localized: "Selection"), values: selectionValues, to: selectionSection)
        selectionSection.isHidden = true
        stack.addArrangedSubview(selectionSection)

        let goalTitle = heading(String(localized: "Word goal"))
        stack.addArrangedSubview(goalTitle)
        goalField.borderStyle = .roundedRect
        goalField.keyboardType = .numberPad
        goalField.font = .preferredFont(forTextStyle: .body)
        goalField.adjustsFontForContentSizeCategory = true
        goalField.placeholder = String(localized: "Enter a word goal")
        goalField.accessibilityLabel = String(localized: "Word goal")
        goalField.accessibilityHint = String(localized: "Clear the field to remove the goal.")
        goalField.accessibilityIdentifier = "stats.goal"
        goalField.addTarget(self, action: #selector(goalChanged), for: .editingChanged)
        goalField.addTarget(self, action: #selector(goalEditingEnded), for: .editingDidEnd)
        goalField.addTarget(self, action: #selector(dismissKeyboard), for: .editingDidEndOnExit)
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: String(localized: "Done"), style: .done,
                            target: self, action: #selector(dismissKeyboard))
        ]
        goalField.inputAccessoryView = toolbar
        stack.addArrangedSubview(goalField)

        goalError.font = .preferredFont(forTextStyle: .footnote)
        goalError.adjustsFontForContentSizeCategory = true
        goalError.textColor = .systemRed
        goalError.numberOfLines = 0
        goalError.isHidden = true
        stack.addArrangedSubview(goalError)

        progress.isAccessibilityElement = true
        progress.accessibilityLabel = String(localized: "Word goal progress")
        stack.addArrangedSubview(progress)
        progressLabel.font = .preferredFont(forTextStyle: .body)
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.numberOfLines = 0
        progressLabel.isAccessibilityElement = false
        stack.addArrangedSubview(progressLabel)

        stack.addArrangedSubview(heading(String(localized: "Today")))
        dailyField.borderStyle = .roundedRect
        dailyField.keyboardType = .numberPad
        dailyField.font = .preferredFont(forTextStyle: .body)
        dailyField.adjustsFontForContentSizeCategory = true
        dailyField.placeholder = String(localized: "Off")
        dailyField.accessibilityLabel = String(localized: "Daily target")
        dailyField.accessibilityHint = String(localized: "Words written today, in every document. Resets at midnight. Clear the field to remove the target.")
        dailyField.accessibilityIdentifier = "stats.dailyTarget"
        dailyField.text = dailyWords.target.map(String.init)
        dailyField.inputAccessoryView = toolbar
        dailyField.addTarget(self, action: #selector(saveDailyTarget), for: .editingDidEnd)
        stack.addArrangedSubview(dailyField)
        dailyError.font = .preferredFont(forTextStyle: .footnote)
        dailyError.textColor = .systemRed
        dailyError.numberOfLines = 0
        dailyError.isHidden = true
        stack.addArrangedSubview(dailyError)
        dailyProgress.isAccessibilityElement = true
        dailyProgress.accessibilityLabel = String(localized: "Daily target progress")
        dailyProgress.accessibilityIdentifier = "stats.dailyProgress"
        let ringRow = UIStackView(arrangedSubviews: [dailyProgress, UIView()])
        ringRow.axis = .horizontal
        dailyProgress.widthAnchor.constraint(equalToConstant: 40).isActive = true
        dailyProgress.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(ringRow)
        dailyLabel.font = .preferredFont(forTextStyle: .body)
        dailyLabel.adjustsFontForContentSizeCategory = true
        dailyLabel.numberOfLines = 0
        dailyLabel.accessibilityIdentifier = "stats.dailyLabel"
        stack.addArrangedSubview(dailyLabel)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDaily), name: DailyWordCounter.changed, object: dailyWords)
        refreshDaily()

        do {
            goal = FileWordGoals.goal(for: filePath, in: try readGoals())
            goalField.text = goal.map(String.init)
        } catch {
            showGoalError(String(localized: "Could not read saved word goals."))
        }
        refreshProgress()
        calculate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dailyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDaily() }
        }
        refreshDaily()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveGoal()
        saveDailyTarget()
        dailyRefreshTimer?.invalidate()
        dailyRefreshTimer = nil
    }

    /// Replaces the snapshot without changing the file whose goal is edited.
    func update(text: String, selection: NSRange, documentLines: Int? = nil) {
        self.text = text
        self.selection = selection
        self.documentLines = documentLines
        if isViewLoaded { calculate() }
    }

    private func addSection(_ name: String, values: [UILabel], to stack: UIStackView) {
        stack.addArrangedSubview(heading(name))
        for label in values {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits.insert(.header)
        return label
    }

    private func calculate() {
        generation += 1
        let requestedGeneration = generation
        let snapshot = text
        let requestedSelection = selection
        isCalculating = true
        if !hasDisplayedCounts {
            let loading = String(localized: "Calculating…")
            for label in documentValues + selectionValues { label.text = loading; label.accessibilityLabel = loading }
            selectionSection.isHidden = true
            refreshProgress()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ns = snapshot as NSString
            let start = min(max(0, requestedSelection.location), ns.length)
            let length = min(max(0, requestedSelection.length), ns.length - start)
            let document = TextStats.count(ns, range: NSRange(location: 0, length: ns.length))
            let selected = length > 0 ? TextStats.count(ns, range: NSRange(location: start, length: length)) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.isCalculating = false
                self.hasDisplayedCounts = true
                self.documentCounts = document
                self.selectionSection.isHidden = length == 0
                self.display(document, in: self.documentValues, section: String(localized: "Document"))
                if document == nil, let lines = self.documentLines {
                    let number = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
                    self.documentValues[2].text = String(localized: "Lines: \(number)")
                    self.documentValues[2].accessibilityLabel = String(localized: "Document, Lines, \(number)")
                }
                self.display(selected, in: self.selectionValues, section: String(localized: "Selection"))
                self.refreshProgress()
            }
        }
    }

    private func display(_ counts: TextCounts?, in labels: [UILabel], section: String) {
        let names = [
            String(localized: "Words"),
            String(localized: "Characters"),
            String(localized: "Lines"),
            String(localized: "Reading time")
        ]
        guard let counts else {
            for index in labels.indices {
                let unavailable = String(localized: "Unavailable")
                labels[index].text = String.localizedStringWithFormat(String(localized: "%@: %@"), names[index], unavailable)
                labels[index].accessibilityLabel = String.localizedStringWithFormat(
                    String(localized: "%@, %@, %@"), section, names[index], unavailable)
            }
            return
        }
        let numbers = [counts.words, counts.characters, counts.lines, counts.readingMinutes]
        for index in labels.indices {
            let number = NumberFormatter.localizedString(from: NSNumber(value: numbers[index]), number: .decimal)
            let value = index == 3 ? String(localized: "\(number) min") : number
            labels[index].text = String.localizedStringWithFormat(String(localized: "%@: %@"), names[index], value)
            labels[index].accessibilityLabel = String.localizedStringWithFormat(
                String(localized: "%@, %@, %@"), section, names[index], value)
        }
    }

    private func readGoals() throws -> [FileWordGoal] {
        guard let data = defaults.data(forKey: Self.goalsKey) else { return [] }
        return try JSONDecoder().decode([FileWordGoal].self, from: data)
    }

    @objc func goalChanged() {
        goalIsDirty = true
        goalTimer?.invalidate()
        goalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveGoal() }
        }
    }

    private func saveGoal() {
        goalTimer?.invalidate()
        goalTimer = nil
        guard goalIsDirty else { return }
        let input = goalField.text ?? ""
        let next: Int?
        if input.isEmpty {
            next = nil
        } else if let parsed = WordGoal.parse(input) {
            next = parsed
        } else {
            showGoalError(String(localized: "Enter a whole number from 1 to 10,000,000, or clear the field."))
            return
        }
        do {
            let goals = FileWordGoals.setting(next, for: filePath, in: try readGoals())
            defaults.set(try JSONEncoder().encode(goals), forKey: Self.goalsKey)
            goal = next
            goalIsDirty = false
            goalError.isHidden = true
            goalField.accessibilityValue = nil
            refreshProgress()
        } catch {
            showGoalError(String(localized: "Could not save word goals."))
        }
    }

    private func showGoalError(_ message: String) {
        goalError.text = message
        goalError.isHidden = false
        goalField.accessibilityValue = message
    }

    @objc func goalEditingEnded() {
        saveGoal()
        if !goalError.isHidden, let message = goalError.text {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    @objc private func dismissKeyboard() {
        goalField.resignFirstResponder()
        dailyField.resignFirstResponder()
    }

    @objc func saveDailyTarget() {
        let input = dailyField.text ?? ""
        if !input.isEmpty && WordGoal.parse(input) == nil {
            let message = String(localized: "Enter a whole number from 1 to 10,000,000, or clear the field.")
            dailyError.text = message
            dailyError.isHidden = false
            dailyField.accessibilityValue = message
            return
        }
        dailyError.isHidden = true
        dailyField.accessibilityValue = nil
        dailyWords.setTarget(WordGoal.parse(input))
        refreshDaily()
    }

    @objc private func refreshDaily() {
        let written = dailyWords.wordsToday
        let ws = NumberFormatter.localizedString(from: NSNumber(value: written), number: .decimal)
        guard let target = dailyWords.target else {
            dailyProgress.progress = 0
            dailyLabel.text = String(localized: "\(ws) words today. Set a target for today.")
            dailyProgress.accessibilityValue = dailyLabel.text
            return
        }
        let gs = NumberFormatter.localizedString(from: NSNumber(value: target), number: .decimal)
        let pct = WordGoal.percent(words: written, goal: target)
        dailyProgress.progress = CGFloat(WordGoal.progress(words: written, goal: target))
        dailyLabel.text = String(localized: "\(ws) of \(gs) words today (\(pct) %)")
        dailyProgress.accessibilityValue = dailyLabel.text
    }

    @objc private func dismissSheet() { dismiss(animated: true) }

    private func refreshProgress() {
        guard let goal else {
            progress.progress = 0
            progressLabel.text = String(localized: "No word goal set")
            progress.accessibilityValue = progressLabel.text
            return
        }
        guard let words = documentCounts?.words else {
            progress.progress = 0
            progressLabel.text = isCalculating ? String(localized: "Calculating…") : String(localized: "Unavailable")
            progress.accessibilityValue = progressLabel.text
            return
        }
        progress.progress = Float(WordGoal.progress(words: words, goal: goal))
        let percent = WordGoal.percent(words: words, goal: goal)
        let number = NumberFormatter.localizedString(from: NSNumber(value: percent), number: .decimal)
        progressLabel.text = String.localizedStringWithFormat(String(localized: "%@%%"), number)
        progress.accessibilityValue = String.localizedStringWithFormat(
            String(localized: "%@ percent"), number)
    }
}
