//
//  DictionaryRootView.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/5.
//
import SwiftUI

struct DictionaryRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.dictionaryService != nil {
                DictionarySearchView()
            } else {
                ContentUnavailableView(
                    "Dictionary Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text("词典服务未就绪，请稍后重试。")
                )
            }
        }
        .navigationTitle("Dictionary")
    }
}
