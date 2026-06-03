//
//  FuckYouXcodeApp.swift
//  FuckYouXcode
//
//  Created by 马逸凡 on 2026/2/5.
//

import SwiftUI

@main
struct FuckYouXcodeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBootstrapAlertPresented = false
    @AppStorage(AppAppearanceController.darkModeStorageKey) private var isDarkModeEnabled = false

    @StateObject private var speechSettings = SpeechSettings()
    @StateObject private var appState = AppState()
    @StateObject private var selectionManager = SelectionManager()
    @StateObject private var aiSettingsStore = AISettingsStore()
    @StateObject private var aiChatHistoryStore = AIChatHistoryStore()
    
    var body: some Scene {
        WindowGroup {
            Group {
                if let service = appState.dictionaryService {
                    ContentView(dictionaryService: service)
                        .environmentObject(speechSettings)
                        .environmentObject(selectionManager)
                        .environmentObject(appState)
                        .environmentObject(aiSettingsStore)
                        .environmentObject(aiChatHistoryStore)
                } else if let message = appState.bootstrapErrorMessage, !appState.isBootstrapping {
                    ContentUnavailableView(
                        "词典加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                } else {
                    ProgressView("Loading Dictionary…")
                }
            }
            .task {
                await MainActor.run {
                    AppAppearanceController.applyDarkMode(isDarkModeEnabled)
                }
                await appState.bootstrap()
#if DEBUG
                if appState.bootstrapErrorMessage == nil {
                    await appState.importOxfordDictionaryForTestingIfNeeded()
                }
#endif
                // TEMP: iCloud disabled
                // await UserCloudSyncService.shared.bootstrap()
            }
            .onChange(of: appState.bootstrapErrorMessage) { _, newValue in
                isBootstrapAlertPresented = newValue != nil
            }
            .alert("词典加载失败", isPresented: $isBootstrapAlertPresented) {
                Button("取消", role: .cancel) {}
                Button("重试") {
                    Task {
                        await appState.retryBootstrap()
                    }
                }
            } message: {
                Text(appState.bootstrapErrorMessage ?? "请稍后再试。")
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { @MainActor in
                    AppAppearanceController.applyDarkMode(isDarkModeEnabled)
                }
                Task {
                    // TEMP: iCloud disabled
                    // await UserCloudSyncService.shared.sceneDidBecomeActive()
                }
            }
        }
    }
    
}
 
