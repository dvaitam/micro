import Foundation
import Combine

@MainActor
final class SubmitViewModel: ObservableObject {
    @Published var code: String = ""
    @Published var language: LanguageOption = .go
    @Published var statusLog: [StatusLogEntry] = []
    @Published var isSubmitting = false
    @Published var latestSubmission: SubmissionDetail?
    @Published var submissionId: Int?

    private var pollTask: Task<Void, Never>?

    func prefillSample(for lang: LanguageOption) {
        switch lang {
        case .go:
            code = """
package main
import "fmt"

func main() {
    // Your solution here
    fmt.Println("hello")
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .c:
            code = """
#include <stdio.h>

int main() {
    // Your solution here
    printf("hello\n");
    return 0;
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .cpp:
            code = """
#include <bits/stdc++.h>
using namespace std;

int main() {
    ios::sync_with_stdio(false);
    cin.tie(nullptr);
    // Your solution here
    cout << "hello\n";
    return 0;
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .py:
            code = """
# Your solution here
print("hello")
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .rs:
            code = """
fn main() {
    // Your solution here
    println!("hello");
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .java:
            code = """
import java.io.*;
import java.util.*;

public class Main {
    public static void main(String[] args) throws Exception {
        // Your solution here
        System.out.println("hello");
    }
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        case .kotlin:
            code = """
fun main() {
    // Your solution here
    println("hello")
}
""".trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func submit(problem: Problem, client: CodeforcesAPIClient) async {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendStatus(status: "error", detail: "Code is empty")
            return
        }
        isSubmitting = true
        appendStatus(status: "info", detail: "Submitting to \(problem.contestId)\(problem.index)...")
        do {
            let response = try await client.submit(contest: String(problem.contestId), index: problem.index, lang: language, code: code)
            submissionId = response.submissionId
            appendStatus(status: response.status ?? "submitted", detail: "Submission #\(response.submissionId ?? 0)")
            if let submissionId {
                startPolling(id: submissionId, client: client)
            }
        } catch {
            appendStatus(status: "error", detail: error.localizedDescription)
            isSubmitting = false
        }
    }

    func startPolling(id: Int, client: CodeforcesAPIClient) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.checkCancellation()
                do {
                    let detail = try await client.fetchSubmission(id: id)
                    await MainActor.run {
                        self.latestSubmission = detail
                        self.appendStatus(status: detail.status, detail: detail.verdict ?? detail.stdout ?? "")
                    }
                    if detail.isTerminal { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    await MainActor.run { self.appendStatus(status: "error", detail: error.localizedDescription) }
                    break
                }
            }
            await MainActor.run { self.isSubmitting = false }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    private func appendStatus(status: String, detail: String) {
        statusLog.insert(StatusLogEntry(timestamp: Date(), status: status, detail: detail.isEmpty ? status : detail), at: 0)
    }
}
