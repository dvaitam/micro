import Foundation
import Combine

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published var favorites: [Problem] = []
    @Published var favoriteIDs: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var client: CodeforcesAPIClient?

    func attach(client: CodeforcesAPIClient) {
        self.client = client
    }

    func loadFavorites() async {
        guard let client else { return }
        guard client.accessToken != nil else {
            favorites = []
            favoriteIDs = []
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let list = try await client.fetchFavorites()
            favorites = list
            favoriteIDs = Set(list.map { $0.id })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func isFavorite(_ problem: Problem) -> Bool {
        favoriteIDs.contains(problem.id)
    }

    func toggleFavorite(_ problem: Problem) async {
        guard let client else { return }
        if isFavorite(problem) {
            favoriteIDs.remove(problem.id)
            favorites.removeAll { $0.id == problem.id }
            do {
                try await client.removeFavorite(contestId: problem.contestId, index: problem.index)
            } catch {
                favoriteIDs.insert(problem.id)
                favorites.append(problem)
                errorMessage = error.localizedDescription
            }
        } else {
            favoriteIDs.insert(problem.id)
            favorites.insert(problem, at: 0)
            do {
                try await client.addFavorite(contestId: problem.contestId, index: problem.index)
            } catch {
                favoriteIDs.remove(problem.id)
                favorites.removeAll { $0.id == problem.id }
                errorMessage = error.localizedDescription
            }
        }
    }
}
