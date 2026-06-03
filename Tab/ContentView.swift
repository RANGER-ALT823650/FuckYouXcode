//
//  ContentView.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/2.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    let dictionaryService: DictionaryService
    
    
    var body: some View {
        ZStack{
            TabView(selection: $selectedTab) {
                SearchWordsFromVideosView(dictionaryService: dictionaryService)
                    .tabItem { Label("图片识词", systemImage: "camera.metering.center.weighted.average") }
                    .tag(0)
                WordsCollectionView(dictionaryService: dictionaryService)
                    .tabItem { Label("集", systemImage: "folder.fill") }
                    .tag(1)
                DictionaryRootView()
                    .tabItem { Label("搜索", systemImage:"magnifyingglass")}
                    .tag(2)
            }
            .onChange(of: selectedTab) { _, _ in
                Haptics.soft()   // ✅ Tab 切换：建议 soft / light
            }
        }
    }
}
