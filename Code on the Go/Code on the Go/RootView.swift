import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    @EnvironmentObject private var problemsViewModel: ProblemsViewModel
    @EnvironmentObject private var favoritesViewModel: FavoritesViewModel

    var body: some View {
        TabView {
            ProblemsTab()
                .tabItem {
                    Label("Problems", systemImage: "list.bullet")
                }
            FavoritesTab()
                .tabItem {
                    Label("Favorites", systemImage: "star.fill")
                }
        }
        .task {
            problemsViewModel.attach(client: apiClient)
            favoritesViewModel.attach(client: apiClient)
            await problemsViewModel.loadTagsIfNeeded()
            await problemsViewModel.loadProblems(resetPage: true)
            await favoritesViewModel.loadFavorites()
        }
    }
}

// MARK: - Problems Tab

struct ProblemsTab: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    @EnvironmentObject private var problemsViewModel: ProblemsViewModel
    @EnvironmentObject private var favoritesViewModel: FavoritesViewModel
    @State private var selectedProblem: Problem?
    @State private var showingLogin = false
    @State private var showingSubmit = false
    @StateObject private var submitVM = SubmitViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Problems")
                .toolbar { toolbarContent }
        } detail: {
            if let problem = selectedProblem {
                ProblemDetailView(problem: problem)
                    .id(problem.id)
            } else {
                ContentUnavailableView("Select a problem", systemImage: "list.bullet")
            }
        }
        .onChange(of: problemsViewModel.problems) { newValue in
            if let selectedProblem, newValue.contains(where: { $0.id == selectedProblem.id }) {
                return
            }
            selectedProblem = newValue.first
        }
        .sheet(isPresented: $showingLogin) {
            NavigationStack {
                LoginPage()
            }
        }
        .fullScreenCover(isPresented: $showingSubmit) {
            NavigationStack {
                SubmitPage(problem: selectedProblem, submitVM: submitVM)
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showingLogin = true }) {
                Label("Login", systemImage: "person.crop.circle.badge.plus")
            }
            Button(action: { showingSubmit = true }) {
                Label("Submit", systemImage: "paperplane.fill")
            }
            .disabled(selectedProblem == nil)
            Button(action: { Task { await problemsViewModel.loadProblems(resetPage: true) } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<String?>(
            get: { selectedProblem?.id },
            set: { id in
                selectedProblem = id.flatMap { id in problemsViewModel.problems.first { $0.id == id } }
            }
        )) {
            Section {
                LoginSummaryView()
                SearchBar(text: $problemsViewModel.searchQuery, placeholder: "Search by ID (475D) or title…")
                    .onChange(of: problemsViewModel.searchQuery) { _ in
                        problemsViewModel.onSearchQueryChanged()
                    }
                if !problemsViewModel.isSearching {
                    HStack {
                        Text("Sort")
                            .font(.headline)
                        Spacer()
                        Picker("Sort", selection: $problemsViewModel.sort) {
                            ForEach(SortOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .onChange(of: problemsViewModel.sort) { _ in
                        problemsViewModel.onSortChanged()
                    }
                    TagSelectorView(tags: problemsViewModel.tags,
                                    selected: Binding(get: { problemsViewModel.selectedTags }, set: { problemsViewModel.selectedTags = $0 }),
                                    mode: $problemsViewModel.tagsMode) {
                        Task { await problemsViewModel.loadProblems(resetPage: true) }
                    }
                }
                if let error = problemsViewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                if problemsViewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .listRowSeparator(.hidden)

            Section {
                ForEach(problemsViewModel.problems) { problem in
                    ProblemRow(problem: problem, isSelected: selectedProblem?.id == problem.id, isFavorite: favoritesViewModel.isFavorite(problem)) {
                        Task { await favoritesViewModel.toggleFavorite(problem) }
                    }
                        .tag(problem.id)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedProblem?.id == problem.id ? Color.accentColor.opacity(0.12) : Color(UIColor.secondarySystemBackground))
                                .padding(.vertical, 2)
                        )
                }
                if problemsViewModel.problems.isEmpty {
                    Text("No problems available.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .listRowSeparator(.hidden)

            Section {
                paginationControls
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private var paginationControls: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Prev") { Task { await problemsViewModel.prevPage() } }
                    .disabled(problemsViewModel.page == 0 || problemsViewModel.isLoading)
                Spacer()
                Text("Page \(problemsViewModel.page + 1) of \(problemsViewModel.totalPages)")
                    .foregroundColor(.secondary)
                Spacer()
                Button("Next") { Task { await problemsViewModel.nextPage() } }
                    .disabled(problemsViewModel.page + 1 >= problemsViewModel.totalPages || problemsViewModel.isLoading)
            }
            .buttonStyle(.bordered)
            HStack(spacing: 6) {
                TextField("#", text: $problemsViewModel.goToPageText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit { Task { await problemsViewModel.goToPage() } }
                Button("Go") { Task { await problemsViewModel.goToPage() } }
                    .buttonStyle(.bordered)
                    .disabled(problemsViewModel.goToPageText.isEmpty)
                Spacer()
                Text("\(problemsViewModel.totalCount) total")
                    .foregroundColor(.secondary)
            }
        }
        .font(.footnote)
    }
}

// MARK: - Favorites Tab

struct FavoritesTab: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    @EnvironmentObject private var favoritesViewModel: FavoritesViewModel
    @State private var selectedProblem: Problem?
    @State private var showingSubmit = false
    @StateObject private var submitVM = SubmitViewModel()

    var body: some View {
        NavigationSplitView {
            favoriteSidebar
                .navigationTitle("Favorites")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: { showingSubmit = true }) {
                            Label("Submit", systemImage: "paperplane.fill")
                        }
                        .disabled(selectedProblem == nil)
                        Button(action: { Task { await favoritesViewModel.loadFavorites() } }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
        } detail: {
            if let problem = selectedProblem {
                ProblemDetailView(problem: problem)
                    .id(problem.id)
            } else {
                ContentUnavailableView("Select a favorite", systemImage: "star")
            }
        }
        .fullScreenCover(isPresented: $showingSubmit) {
            NavigationStack {
                SubmitPage(problem: selectedProblem, submitVM: submitVM)
            }
        }
    }

    private var favoriteSidebar: some View {
        List(selection: Binding<String?>(
            get: { selectedProblem?.id },
            set: { id in
                selectedProblem = id.flatMap { id in favoritesViewModel.favorites.first { $0.id == id } }
            }
        )) {
            if apiClient.accessToken == nil {
                Section {
                    ContentUnavailableView("Sign in to see favorites", systemImage: "person.crop.circle")
                }
                .listRowSeparator(.hidden)
            } else if favoritesViewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowSeparator(.hidden)
            } else if favoritesViewModel.favorites.isEmpty {
                Section {
                    ContentUnavailableView("No favorites yet", systemImage: "star")
                }
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(favoritesViewModel.favorites) { problem in
                        ProblemRow(problem: problem, isSelected: selectedProblem?.id == problem.id, isFavorite: true) {
                            Task { await favoritesViewModel.toggleFavorite(problem) }
                        }
                            .tag(problem.id)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selectedProblem?.id == problem.id ? Color.accentColor.opacity(0.12) : Color(UIColor.secondarySystemBackground))
                                    .padding(.vertical, 2)
                            )
                    }
                }
                .listRowSeparator(.hidden)
            }

            if let error = favoritesViewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}


struct ProblemRow: View {
    let problem: Problem
    let isSelected: Bool
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(problem.contestId)\(problem.index)")
                        .fontWeight(.semibold)
                    if let rating = problem.rating {
                        Label("\(rating)", systemImage: "bolt.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundColor(.orange)
                            .font(.footnote)
                    }
                }
                Text(problem.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let tags = problem.tags, !tags.isEmpty {
                    Text(tags.prefix(4).joined(separator: ", "))
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
            }
            Spacer()
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundColor(isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
    }
}

struct TagSelectorView: View {
    let tags: [String]
    @Binding var selected: Set<String>
    @Binding var mode: TagsMode
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(TagsMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            if tags.isEmpty {
                Text("No tags available")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            let isOn = selected.contains(tag)
                            Button(action: {
                                if isOn { selected.remove(tag) } else { selected.insert(tag) }
                                onChange()
                            }) {
                                Text(tag)
                                    .font(.footnote)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isOn ? Color.accentColor.opacity(0.2) : Color(UIColor.secondarySystemBackground))
                                    .foregroundColor(isOn ? .accentColor : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct LoginSummaryView: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient

    var body: some View {
        HStack {
            if let email = apiClient.email, !email.isEmpty {
                Label(email, systemImage: "person.fill")
                    .font(.subheadline)
                Spacer()
                Button("Logout") { apiClient.logout() }
                    .buttonStyle(.bordered)
            } else {
                Label("Not signed in", systemImage: "person")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct WebStatementView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.isScrollEnabled = true
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let current = uiView.url
        if current != url {
            uiView.load(URLRequest(url: url))
        }
    }
}

struct LoginPage: View {
    @State private var email = ""
    @State private var otp = ""
    @State private var stayLoggedIn = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sign in with the API email OTP flow.")
                    .foregroundColor(.secondary)
                LoginCard(email: $email, otp: $otp, stayLoggedIn: $stayLoggedIn)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
            }
            .padding()
        }
        .navigationTitle("Login")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

struct SubmitPage: View {
    let problem: Problem?
    @ObservedObject var submitVM: SubmitViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let problem {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(problem.contestId)\(problem.index)")
                            .font(.headline)
                        Text(problem.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    SubmitView(problem: problem, submitVM: submitVM)
                } else {
                    ContentUnavailableView("Select a problem to submit", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding()
        }
        .navigationTitle("Submit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
