//
//  DictionarySearchView.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/5.
//
import SwiftUI

struct DictionarySearchView: View {
    @EnvironmentObject private var appState: AppState

    private enum SearchHistoryMode: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case deep = "Deep"

        var id: String { rawValue }

        var storageKey: String {
            switch self {
            case .fast:
                return "dictionary.search.history.fast"
            case .deep:
                return "dictionary.search.history.deep"
            }
        }
    }

    private let legacyHistoryStorageKey = "dictionary.search.history"

    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var fastSearchHistory: [String] = []
    @State private var deepSearchHistory: [String] = []
    @State private var searchHistoryMode: SearchHistoryMode = .fast
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var fadingText: String = ""
    @State private var fadingOpacity: Double = 0
    @State private var path: [String] = []
    @State private var wordPreviews: [String: WordListPreviewRaw] = [:]
    @State private var suggestionTask: Task<Void, Never>?
    @State private var previewLoadTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var activeService: DictionaryService? {
        appState.service(for: appState.selectedDictionaryID)
    }

    private var suggestionService: DictionaryService? {
        guard appState.option(for: appState.selectedDictionaryID)?.sourceKind == .imported else {
            return activeService
        }
        return appState.service(for: DictionaryOption.defaultID) ?? activeService
    }

    private var previewService: DictionaryService? {
        appState.service(for: DictionaryOption.defaultID) ?? activeService
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentSearchHistory: [String] {
        switch searchHistoryMode {
        case .fast:
            return fastSearchHistory
        case .deep:
            return deepSearchHistory
        }
    }

    private var displayedWords: [String] {
        trimmedQuery.isEmpty ? currentSearchHistory : suggestions
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                HStack {
                    ZStack(alignment: .leading) {
                        TextField("  🔍Search a word…", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.default)
                            .submitLabel(.search)
                            .focused($isSearchFocused)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 40)
                            .onChange(of: query) { _, newValue in
                                scheduleSuggestionsRefresh(for: newValue)
                            }
                            .padding(12)
                            .onSubmit {
                                submitSearch(query)
                            }

                        if !fadingText.isEmpty {
                            Text(fadingText)
                                .font(.system(size: 20, weight: .regular))
                                .padding(12)
                                .opacity(fadingOpacity)
                                .allowsHitTesting(false)
                        }
                    }

                    if !query.isEmpty {
                        Button {
                            fadingText = query
                            fadingOpacity = 1

                            withAnimation(.easeOut(duration: 0.2)) {
                                fadingOpacity = 0
                            }

                            query = ""
                            DispatchQueue.main.async {
                                isSearchFocused = true
                            }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                                fadingText = ""
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .padding(.trailing, 12)
                        .transition(.opacity)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 17)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .padding(20)
                .animation(.easeOut(duration: 0.15), value: query.isEmpty)

                if !isSearchFocused {
                    Picker("Mode", selection: $searchHistoryMode) {
                        ForEach(SearchHistoryMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                List {
                    ForEach(displayedWords, id: \.self) { word in
                        NavigationLink(value: word) {
                            wordRow(word)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if trimmedQuery.isEmpty {
                                Button(role: .destructive) {
                                    removeFromSearchHistory(word)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                addToFavorites(word)
                            } label: {
                                Label("收藏", systemImage: "star.fill")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .overlay {
                    if trimmedQuery.isEmpty {
                        if currentSearchHistory.isEmpty {
                            ContentUnavailableView(
                                "\(searchHistoryMode.rawValue) 模式下没有历史记录",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    } else if isLoading {
                        ProgressView()
                    }
                }
            }
            .onAppear {
                loadSearchHistory()
                loadWordPreviews(for: displayedWords)
            }
            .onDisappear {
                suggestionTask?.cancel()
                previewLoadTask?.cancel()
            }
            .onChange(of: path) { _, newValue in
                guard let last = newValue.last else { return }
                addToSearchHistory(last)
            }
            .onChange(of: appState.selectedDictionaryID) { _, _ in
                suggestions = []
                if !trimmedQuery.isEmpty {
                    scheduleSuggestionsRefresh(for: trimmedQuery, debounceNanoseconds: 0)
                } else {
                    loadWordPreviews(for: currentSearchHistory)
                }
            }
            .onChange(of: searchHistoryMode) { _, _ in
                Haptics.soft()
                guard trimmedQuery.isEmpty else { return }
                loadWordPreviews(for: currentSearchHistory)
            }
            .animation(.easeInOut(duration: 0.22), value: isSearchFocused)
            .navigationDestination(for: String.self) { word in
                if let service = activeService {
                    DictionaryEntryView(service: service, word: word)
                } else {
                    ContentUnavailableView(
                        "词典不可用",
                        systemImage: "book.closed"
                    )
                }
            }
        }
    }

    @MainActor
    private func refreshSuggestions(_ text: String) async {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            loadWordPreviews(for: currentSearchHistory)
            return
        }

        guard let service = suggestionService else {
            suggestions = []
            wordPreviews = [:]
            errorMessage = "当前词典未就绪"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let resolvedSuggestions = try await service.suggestions(trimmed, limit: 30)
            guard !Task.isCancelled else { return }
            guard trimmedQuery == trimmed else { return }
            suggestions = resolvedSuggestions
            loadWordPreviews(for: resolvedSuggestions)
        } catch {
            guard trimmedQuery == trimmed else { return }
            errorMessage = error.localizedDescription
            suggestions = []
            wordPreviews = [:]
        }
    }

    private func scheduleSuggestionsRefresh(
        for text: String,
        debounceNanoseconds: UInt64 = 200_000_000
    ) {
        suggestionTask?.cancel()
        suggestionTask = Task {
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await refreshSuggestions(text)
        }
    }

    private func submitSearch(_ rawInput: String) {
        let word = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }

        isSearchFocused = false
        path.append(word)
    }

    private func loadSearchHistory() {
        migrateLegacySearchHistoryIfNeeded()
        fastSearchHistory = UserDefaults.standard.stringArray(forKey: SearchHistoryMode.fast.storageKey) ?? []
        deepSearchHistory = UserDefaults.standard.stringArray(forKey: SearchHistoryMode.deep.storageKey) ?? []
    }

    private func addToSearchHistory(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }

        var updatedHistory = currentSearchHistory
        updatedHistory.removeAll { $0 == word }
        updatedHistory.insert(word, at: 0)

        if updatedHistory.count > 50 {
            updatedHistory = Array(updatedHistory.prefix(50))
        }

        saveSearchHistory(updatedHistory, for: searchHistoryMode)

        if trimmedQuery.isEmpty {
            loadWordPreviews(for: updatedHistory)
        }
    }

    private func removeFromSearchHistory(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }

        let updatedHistory = currentSearchHistory.filter { $0 != word }
        saveSearchHistory(updatedHistory, for: searchHistoryMode)

        if trimmedQuery.isEmpty {
            loadWordPreviews(for: updatedHistory)
        }
    }

    private func addToFavorites(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }

        Task {
            do {
                _ = try await UserDataService.shared.addFavorite(word: word)
                await MainActor.run {
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }

    private func migrateLegacySearchHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        let hasFastHistory = defaults.object(forKey: SearchHistoryMode.fast.storageKey) != nil
        let hasDeepHistory = defaults.object(forKey: SearchHistoryMode.deep.storageKey) != nil

        guard !hasFastHistory, !hasDeepHistory else { return }

        let legacyHistory = defaults.stringArray(forKey: legacyHistoryStorageKey) ?? []
        defaults.set(legacyHistory, forKey: SearchHistoryMode.fast.storageKey)
        defaults.set([], forKey: SearchHistoryMode.deep.storageKey)
    }

    private func saveSearchHistory(_ history: [String], for mode: SearchHistoryMode) {
        switch mode {
        case .fast:
            fastSearchHistory = history
        case .deep:
            deepSearchHistory = history
        }

        UserDefaults.standard.set(history, forKey: mode.storageKey)
    }

    private func wordRow(_ word: String) -> some View {
        HStack(spacing: 10) {
            Text(word)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if let preview = wordPreviews[word]?.compactPreviewText(posStyle: .abbreviation), !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 8)
            }
        }
    }

    @MainActor
    private func loadWordPreviews(for words: [String]) {
        previewLoadTask?.cancel()

        guard let service = previewService, !words.isEmpty else {
            wordPreviews = [:]
            return
        }

        let snapshot = words
        previewLoadTask = Task {
            do {
                let previews = try await service.fetchWordListPreviews(words: snapshot)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard displayedWords == snapshot else { return }
                    wordPreviews = previews
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard displayedWords == snapshot else { return }
                    wordPreviews = [:]
                }
            }
        }
    }
}
