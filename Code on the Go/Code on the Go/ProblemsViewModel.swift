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

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

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
            let list = try await client.fetchProblems(limit: pageSize, offset: offset, tags: Array(selectedTags), tagsMode: tagsMode.rawValue)
            problems = list
        } catch {
            errorMessage = error.localizedDescription
            problems = []
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
