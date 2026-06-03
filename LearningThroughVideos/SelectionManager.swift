//
//  SelectionManager.swift
//  FuckYouXcode
//
//  Created by 马逸凡 on 2026/2/14.
//
import Combine
import UIKit

final class SelectionManager: ObservableObject {
    @Published var hasSelection: Bool = false
    weak var activeTextView: UITextView?

    func activate(_ tv: UITextView) {
        activeTextView = tv
        if hasSelection == false { hasSelection = true }
    }

    func deactivateIfCurrent(_ tv: UITextView) {
        if activeTextView === tv {
            activeTextView = nil
        }
        if hasSelection == true { hasSelection = false }
    }

    func clearSelection() {
        guard let tv = activeTextView else { return }

        // ✅ 1) 折叠选区（取消选中）
        let maxLen = tv.attributedText.length
        let loc = min(tv.selectedRange.location, maxLen)
        tv.selectedRange = NSRange(location: loc, length: 0)

        // ✅ 2) 收起菜单（iOS16+ 与旧版本都尽量兼容）
        tv.resignFirstResponder()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        if #available(iOS 16.0, *) {
            tv.interactions
                .compactMap { $0 as? UIEditMenuInteraction }
                .forEach { $0.dismissMenu() }
        } else {
            UIMenuController.shared.hideMenu()
        }

        // ✅ 3) 清理状态
        activeTextView = nil
        hasSelection = false
    }
}

