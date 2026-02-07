import Foundation

struct Problem: Identifiable, Hashable {
    let backendId: Int?
    let contestId: String
    let index: String
    let title: String
    let rating: Int?
    let tags: [String]?
    let solvedCount: Int?

    var id: String { "\(contestId)\(index)" }
    var displayRating: String { rating != nil ? "rating \(rating!)" : "rating —" }
    var statementURL: URL? {
        URL(string: "https://cdn.manchik.co.uk/contest/\(contestId)/problem/\(index)")
    }
}

struct SubmissionCreateResponse: Decodable {
    let status: String?
    let submissionId: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case submissionId = "submission_id"
    }
}

struct SubmissionDetail: Decodable, Identifiable {
    let id: Int
    let contestId: String?
    let index: String?
    let status: String
    let verdict: String?
    let stdout: String?
    let stderr: String?
    let response: String?
    let code: String?
    let lang: String?
    let timestamp: String?
    let exitCode: Int?

    var isTerminal: Bool {
        let s = status.lowercased()
        if ["queued", "pending", "running", "in_progress", "processing"].contains(s) {
            return false
        }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case contestId = "contest_id"
        case index
        case status
        case verdict
        case stdout
        case stderr
        case response
        case code
        case lang
        case timestamp
        case exitCode = "exit_code"
    }
}

struct AuthTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let email: String
}

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .unauthorized: return "Unauthorized"
        case .message(let msg): return msg
        }
    }
}

struct ProblemsResponse: Decodable {
    let problems: [ProblemDTO]
    let total: Int
}

enum SortOption: String, CaseIterable, Identifiable {
    case `default` = ""
    case ratingAsc = "rating_asc"
    case ratingDesc = "rating_desc"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "Default (Contest)"
        case .ratingAsc: return "Rating (Low to High)"
        case .ratingDesc: return "Rating (High to Low)"
        }
    }
}

struct ProblemDTO: Decodable {
    let backendId: Int?
    let contestId: String
    let index: String
    let title: String
    let rating: Int?
    let tags: [String]?
    let solvedCount: Int?

    enum CodingKeys: String, CodingKey {
        case backendId = "id"
        case contestId = "contest_id"
        case index
        case title
        case rating
        case tags
        case solvedCount = "solved"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendId = try? container.decode(Int.self, forKey: .backendId)
        contestId = (try? container.decode(String.self, forKey: .contestId)) ??
            String((try? container.decode(Int.self, forKey: .contestId)) ?? 0)
        index = (try? container.decode(String.self, forKey: .index)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        rating = ProblemDTO.decodeIntIfPresent(container: container, key: .rating)
        tags = try? container.decodeIfPresent([String].self, forKey: .tags)
        solvedCount = ProblemDTO.decodeIntIfPresent(container: container, key: .solvedCount)
    }

    func toProblem() -> Problem {
        Problem(
            backendId: backendId,
            contestId: contestId,
            index: index,
            title: title,
            rating: rating,
            tags: tags,
            solvedCount: solvedCount
        )
    }

    private static func decodeIntIfPresent(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) { return intVal }
        if let strVal = try? container.decodeIfPresent(String.self, forKey: key), let intVal = Int(strVal) { return intVal }
        return nil
    }
}

struct StatusLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let status: String
    let detail: String
}

enum LanguageOption: String, CaseIterable, Identifiable {
    case go, c, cpp, py, rs, java, kotlin

    var id: String { rawValue }
    var label: String {
        switch self {
        case .go: return "Go"
        case .c: return "C"
        case .cpp: return "C++"
        case .py: return "Python"
        case .rs: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        }
    }
}
