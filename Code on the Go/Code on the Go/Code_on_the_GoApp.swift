//
//  Code_on_the_GoApp.swift
//  Code on the Go
//
//  Created by Anil Manchikatla on 05/02/2026.
//

import SwiftUI

@main
struct Code_on_the_GoApp: App {
    @StateObject private var apiClient = CodeforcesAPIClient()
    @StateObject private var problemsViewModel = ProblemsViewModel()
    @StateObject private var favoritesViewModel = FavoritesViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(apiClient)
                .environmentObject(problemsViewModel)
                .environmentObject(favoritesViewModel)
        }
    }
}
