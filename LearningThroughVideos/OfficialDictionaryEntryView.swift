//
//  OfficialDictionaryEntryView.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/2.
//

import SwiftUI
import UIKit

/// ✅ 用于 .sheet 弹出的系统词典页面
/// 核心思路：不要把系统词典 push 进你外层的 NavigationStack，避免导航栏按钮叠加/重复。
struct OfficialDictionaryEntryView: View {
    let term: String
    @Environment(\.dismiss) private var dismiss

    private var lookupTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if !lookupTerm.isEmpty {
                SystemDictionaryView(term: lookupTerm)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Text(term.isEmpty ? "（空）" : term)
                        .font(.title2.bold())
                    Text("系统词典里没有这个词条。")
                        .foregroundStyle(.secondary)

                    Button("关闭") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
                .padding()
            }
        }
    }
}

/// UIKit 封装：把 UIReferenceLibraryViewController 放进独立 UINavigationController
/// 这样系统词典内部的“一级/二级”导航只会出现在它自己的导航栏里，不会和你外层导航栏打架。
struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIViewController {
        let dictVC = UIReferenceLibraryViewController(term: term)

        // ✅ 独立导航栈：系统词典自己处理“返回/前进/选择词典”等按钮
        let nav = UINavigationController(rootViewController: dictVC)
        nav.navigationBar.prefersLargeTitles = false
        nav.navigationBar.isTranslucent = true

        return nav
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 你当前逻辑：每次点击单词都会重新弹一个 sheet，因此无需在这里更新 term
    }
}
