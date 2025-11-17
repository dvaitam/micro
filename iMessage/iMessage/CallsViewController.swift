import UIKit

final class CallsViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Calls"
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Calls coming soon"
        label.textColor = .secondaryLabel
        label.textAlignment = .center

        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

