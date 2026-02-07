import Foundation
import Combine

@MainActor
final class ProblemsViewModel: ObservableObject {
    @Published var problems: [Problem] = []
    @Published var tags: [String] = []
    @Published var selectedTags: Set<String> = []
    @Published var tagsMode: TagsMode = .any
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var page = 0
    @Published var searchQuery = ""
    @Published var sort: SortOption = .default
    @Published var totalCount = 0
    @Published var goToPageText = ""

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    var totalPages: Int { max(1, Int(ceil(Double(totalCount) / Double(pageSize)))) }

    private let pageSize = 15
    private var client: CodeforcesAPIClient?
    private var searchTask: Task<Void, Never>?

    func attach(client: CodeforcesAPIClient) {
        self.client = client
    }

    func loadTagsIfNeeded() async {
        guard let client else { return }
        if !tags.isEmpty { return }
        do {
            tags = try await client.fetchTags()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadProblems(resetPage: Bool = false) async {
        guard let client else { return }
        if resetPage { page = 0 }
        isLoading = true
        errorMessage = nil
        let offset = page * pageSize
        do {
            let result = try await client.fetchProblems(limit: pageSize, offset: offset, tags: Array(selectedTags), tagsMode: tagsMode.rawValue, sort: sort.rawValue)
            problems = result.problems
            totalCount = result.total
        } catch {
            errorMessage = error.localizedDescription
            problems = []
            totalCount = 0
        }
        isLoading = false
    }

    func searchProblems() async {
        guard let client else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await loadProblems(resetPage: true)
            return
        }
        isLoading = true
        errorMessage = nil
        let offset = page * pageSize
        do {
            let list = try await client.searchProblems(query: query, limit: pageSize, offset: offset)
            problems = list
        } catch {
            errorMessage = error.localizedDescription
            problems = []
        }
        isLoading = false
    }

    /// Called whenever the search text changes; debounces by 300ms.
    func onSearchQueryChanged() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            searchTask = Task {
                page = 0
                await loadProblems(resetPage: true)
            }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            page = 0
            await searchProblems()
        }
    }

    func nextPage() async {
        page += 1
        if isSearching {
            await searchProblems()
        } else {
            await loadProblems()
        }
    }

    func prevPage() async {
        page = max(0, page - 1)
        if isSearching {
            await searchProblems()
        } else {
            await loadProblems()
        }
    }

    func goToPage() async {
        guard let p = Int(goToPageText), p >= 1, p <= totalPages else { return }
        page = p - 1
        goToPageText = ""
        if isSearching {
            await searchProblems()
        } else {
            await loadProblems()
        }
    }

    func onSortChanged() {
        searchTask?.cancel()
        searchTask = Task {
            page = 0
            await loadProblems(resetPage: true)
        }
    }
}

enum TagsMode: String, CaseIterable, Identifiable {
    case any
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any"
        case .all: return "All"
        }
    }
}
