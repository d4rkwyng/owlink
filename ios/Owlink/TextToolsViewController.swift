import UIKit
import CedricCore

final class ToolResultViewController: UIViewController {
    private let body: String

    init(title: String, body: String) {
        self.body = body
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "tools.result"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Done"), style: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "tools.done"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Copy"), style: .plain, target: self, action: #selector(copyResult))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "tools.copy"
        let text = UITextView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.text = body
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @objc private func copyResult() { UIPasteboard.general.string = body }
    @objc private func done() { dismiss(animated: true) }
}

final class TodoListViewController: UITableViewController {
    let items: [Todos.Item]
    private let jump: (Int) -> Void

    init(items: [Todos.Item], jump: @escaping (Int) -> Void) {
        self.items = items
        self.jump = jump
        super.init(style: .insetGrouped)
        title = String(localized: "Find TODOs")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "tools.todos"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Done"), style: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "tools.done"
        if items.isEmpty {
            let label = UILabel()
            label.text = String(localized: "No TODOs in this file.")
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            tableView.backgroundView = label
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let item = items[indexPath.row]
        cell.textLabel?.text = "\(item.tag) · \(item.line)"
        cell.detailTextLabel?.text = item.text
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessibilityIdentifier = "tools.todo.\(item.line)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let line = items[indexPath.row].line
        dismiss(animated: true) { [jump] in jump(line) }
    }

    @objc private func done() { dismiss(animated: true) }
}
