import UIKit

final class ChatMessageCell: UITableViewCell {
    private let bubbleView = UIView()
    private let messageLabel = UILabel()

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        selectionStyle = .none
        setupViews()
    }

    private func setupViews() {
        contentView.backgroundColor = .systemBackground

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = 18
        bubbleView.layer.masksToBounds = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0

        bubbleView.addSubview(messageLabel)
        contentView.addSubview(bubbleView)

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75),

            messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12)
        ])
    }

    func configure(with message: ChatMessage, isOutgoing: Bool) {
        messageLabel.text = message.text

        leadingConstraint.isActive = !isOutgoing
        trailingConstraint.isActive = isOutgoing

        if isOutgoing {
            bubbleView.backgroundColor = .systemBlue
            messageLabel.textColor = .white
        } else {
            bubbleView.backgroundColor = .secondarySystemBackground
            messageLabel.textColor = .label
        }
    }
}

