import SwiftUI
import UIKit

struct SubmitView: View {
    let problem: Problem
    @ObservedObject var submitVM: SubmitViewModel
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    @State private var editor: UITextView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Language", selection: $submitVM.language) {
                    ForEach(LanguageOption.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
                Button("Sample") { submitVM.prefillSample(for: submitVM.language) }
                Button("Paste") { pasteFromClipboard() }
                Button("Clear") { submitVM.code = "" }
                Button("Tab") { insertText("\t") }
                Button("Enter") { insertText("\n") }
            }
            CodeEditor(text: $submitVM.code, language: submitVM.language) { view in
                editor = view
            }
                .frame(minHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(UIColor.separator)))
            HStack {
                Button(action: { Task { await submitVM.submit(problem: problem, client: apiClient) } }) {
                    HStack {
                        if submitVM.isSubmitting { ProgressView() }
                        Text("Submit")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiClient.accessToken == nil || submitVM.isSubmitting)
                if apiClient.accessToken == nil {
                    Text("Login required").foregroundColor(.secondary)
                }
            }
            if let submissionId = submitVM.submissionId {
                Text("Submission #\(submissionId)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let detail = submitVM.latestSubmission {
                SubmissionSummary(detail: detail)
            }
            StatusLogView(log: submitVM.statusLog)
        }
    }

    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string {
            submitVM.code = text
        }
    }

    private func insertText(_ addition: String) {
        guard let editor else {
            submitVM.code.append(addition)
            return
        }
        if let range = editor.selectedTextRange {
            editor.replace(range, withText: addition)
            submitVM.code = editor.text
        } else {
            editor.insertText(addition)
            submitVM.code = editor.text
        }
    }
}

struct SubmissionSummary: View {
    let detail: SubmissionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status: \(detail.status)")
                if let verdict = detail.verdict { Text("Verdict: \(verdict)") }
                if let lang = detail.lang { Text(lang).foregroundColor(.secondary) }
            }
            if let stdout = detail.stdout, !stdout.isEmpty {
                DisclosureGroup("Stdout") {
                    ScrollView { Text(stdout).font(.system(.body, design: .monospaced)) }
                        .frame(maxHeight: 120)
                }
            }
            if let stderr = detail.stderr, !stderr.isEmpty {
                DisclosureGroup("Stderr") {
                    ScrollView { Text(stderr).font(.system(.body, design: .monospaced)) }
                        .frame(maxHeight: 120)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }
}

struct StatusLogView: View {
    let log: [StatusLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Status updates")
                    .font(.headline)
                Spacer()
            }
            ForEach(log) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.status.capitalized)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Text(entry.detail)
                    .font(.footnote)
            }
            if log.isEmpty {
                Text("No updates yet")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        }
    }
}

struct CodeEditor: View {
    @Binding var text: String
    var language: LanguageOption
    var onTextViewAvailable: ((UITextView) -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Text("Lines: \(max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HighlightingTextView(text: $text, language: language, onTextViewAvailable: onTextViewAvailable)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct HighlightingTextView: UIViewRepresentable {
    @Binding var text: String
    var language: LanguageOption
    var onTextViewAvailable: ((UITextView) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = true
        view.isSelectable = true
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.smartInsertDeleteType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.backgroundColor = .systemBackground
        view.text = text
        context.coordinator.textView = view
        context.coordinator.applyHighlighting()
        onTextViewAvailable?(view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.autocapitalizationType = .none
        uiView.autocorrectionType = .no
        context.coordinator.language = language
        context.coordinator.applyHighlighting()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingTextView
        weak var textView: UITextView?
        var language: LanguageOption

        init(parent: HighlightingTextView) {
            self.parent = parent
            self.language = parent.language
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            applyHighlighting()
        }

        func applyHighlighting() {
            guard let textView else { return }
            let text = textView.text ?? ""
            let selectedRange = textView.selectedRange

            textView.autocapitalizationType = .none
            textView.autocorrectionType = .no
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            let mutable = NSMutableAttributedString(string: text, attributes: baseAttributes)

            func highlight(pattern: String, color: UIColor) {
                let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                let range = NSRange(location: 0, length: (text as NSString).length)
                regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                    if let matchRange = match?.range {
                        mutable.addAttribute(.foregroundColor, value: color, range: matchRange)
                    }
                }
            }

            // Strings
            highlight(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", color: .systemGreen)
            // Comments
            highlight(pattern: "//.*", color: .systemGray)
            highlight(pattern: "#.*", color: .systemGray)
            highlight(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGray)
            // Numbers
            highlight(pattern: "\\b\\d+\\b", color: .systemPurple)
            // Keywords
            let keywordPattern = "\\b(" + keywords(for: language).joined(separator: "|") + ")\\b"
            highlight(pattern: keywordPattern, color: .systemOrange)

            textView.attributedText = mutable
            textView.selectedRange = selectedRange
            textView.typingAttributes = baseAttributes
        }

        private func keywords(for language: LanguageOption) -> [String] {
            switch language {
            case .go:
                return ["func", "var", "let", "if", "else", "for", "switch", "case", "break", "continue", "return", "struct", "type", "import", "package", "range", "map", "chan", "select", "defer", "go"]
            case .c, .cpp:
                return ["int", "long", "float", "double", "char", "void", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "struct", "class", "template", "auto", "include", "using", "namespace", "const", "constexpr"]
            case .py:
                return ["def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "pass", "break", "continue", "try", "except", "with", "lambda", "yield", "in", "is"]
            case .rs:
                return ["fn", "let", "mut", "struct", "enum", "impl", "trait", "use", "mod", "pub", "match", "if", "else", "loop", "while", "for", "in", "return", "move", "ref"]
            case .java:
                return ["class", "interface", "public", "private", "protected", "static", "void", "int", "double", "float", "boolean", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "package", "import", "new", "throws", "try", "catch"]
            case .kotlin:
                return ["fun", "val", "var", "class", "object", "interface", "if", "else", "when", "for", "while", "return", "import", "package", "in", "is", "as", "null", "true", "false", "try", "catch"]
            }
        }
    }
}
