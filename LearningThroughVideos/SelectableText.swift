import SwiftUI
import UIKit
import Combine

// MARK: - Public Models

public struct HighlightSpan: Hashable {
    public var range: NSRange
    public var color: UIColor
    public init(range: NSRange, color: UIColor) {
        self.range = range
        self.color = color
    }
}

public struct SelectableTextLink: Hashable {
    public var range: NSRange
    public var destination: String

    public init(range: NSRange, destination: String) {
        self.range = range
        self.destination = destination
    }
}

// MARK: - SwiftUI View

public struct SelectableText: View {
    public let text: String

    public var textStyle: UIFont.TextStyle
    public var textColor: UIColor
    public var dataDetectorTypes: UIDataDetectorTypes
    public var isSelectable: Bool
    public var showsMarkMenuActions: Bool

    private var isInteracting: Binding<Bool>?

    // ✅ 渲染用
    public var highlightSpans: [HighlightSpan]
    public var annotationRanges: [NSRange]
    public var dictionaryLinks: [SelectableTextLink]

    // ✅ 菜单回调
    public var isHighlighted: ((NSRange) -> Bool)?
    public var onToggleHighlight: ((NSRange, String) -> Void)? // color string，例如 "yellow"
    public var onAddNote: ((NSRange) -> Void)?
    public var onOpenNote: ((NSRange) -> Void)?
    public var onOpenDictionaryLink: ((String) -> Void)?
    
    @State private var clearSelectionToken: Int = 0

    @State private var height: CGFloat = 24
    
    @EnvironmentObject private var selectionManager: SelectionManager
    
    
    
    public init(
        text: String,
        textStyle: UIFont.TextStyle = .body,
        textColor: UIColor = .label,
        dataDetectorTypes: UIDataDetectorTypes = [],
        isSelectable: Bool = true,
        showsMarkMenuActions: Bool = true,
        isInteracting: Binding<Bool>? = nil,
        highlightSpans: [HighlightSpan] = [],
        annotationRanges: [NSRange] = [],
        dictionaryLinks: [SelectableTextLink] = [],
        isHighlighted: ((NSRange) -> Bool)? = nil,
        onToggleHighlight: ((NSRange, String) -> Void)? = nil,
        onAddNote: ((NSRange) -> Void)? = nil,
        onOpenNote: ((NSRange) -> Void)? = nil,
        onOpenDictionaryLink: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.textStyle = textStyle
        self.textColor = textColor
        self.dataDetectorTypes = dataDetectorTypes
        self.isSelectable = isSelectable
        self.showsMarkMenuActions = showsMarkMenuActions
        self.isInteracting = isInteracting
        self.highlightSpans = highlightSpans
        self.annotationRanges = annotationRanges
        self.dictionaryLinks = dictionaryLinks
        self.isHighlighted = isHighlighted
        self.onToggleHighlight = onToggleHighlight
        self.onAddNote = onAddNote
        self.onOpenNote = onOpenNote
        self.onOpenDictionaryLink = onOpenDictionaryLink
    }

    public var body: some View {
        GeometryReader { geo in
            _SelectableTextViewRepresentable(
                text: text,
                width: geo.size.width,
                dynamicHeight: $height,
                textStyle: textStyle,
                textColor: textColor,
                dataDetectorTypes: dataDetectorTypes,
                isSelectable: isSelectable,
                showsMarkMenuActions: showsMarkMenuActions,
                isInteracting: isInteracting,
                highlightSpans: highlightSpans,
                annotationRanges: annotationRanges,
                dictionaryLinks: dictionaryLinks,
                isHighlighted: isHighlighted,
                onToggleHighlight: onToggleHighlight,
                onAddNote: onAddNote,
                onOpenNote: onOpenNote,
                onOpenDictionaryLink: onOpenDictionaryLink,
                selectionManager: selectionManager
            )
        }
        .frame(height: height)
        .accessibilityLabel(Text(text))
        .contentShape(Rectangle())
    }
}

// MARK: - UIViewRepresentable

private struct _SelectableTextViewRepresentable: UIViewRepresentable {
    let text: String
    let width: CGFloat
    @Binding var dynamicHeight: CGFloat

    let textStyle: UIFont.TextStyle
    let textColor: UIColor
    let dataDetectorTypes: UIDataDetectorTypes
    let isSelectable: Bool
    let showsMarkMenuActions: Bool
    let isInteracting: Binding<Bool>?

    let highlightSpans: [HighlightSpan]
    let annotationRanges: [NSRange]
    let dictionaryLinks: [SelectableTextLink]

    let isHighlighted: ((NSRange) -> Bool)?
    let onToggleHighlight: ((NSRange, String) -> Void)?
    let onAddNote: ((NSRange) -> Void)?
    let onOpenNote: ((NSRange) -> Void)?
    let onOpenDictionaryLink: ((String) -> Void)?

    let selectionManager: SelectionManager


    func makeCoordinator() -> Coordinator {
            Coordinator(
                selectionManager: selectionManager,
                isInteracting: isInteracting,
                showsMarkMenuActions: showsMarkMenuActions,
                onOpenDictionaryLink: onOpenDictionaryLink
            )
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = IntrinsicMenuTextView()

        tv.isEditable = false
        tv.isSelectable = isSelectable
        tv.isScrollEnabled = false

        tv.backgroundColor = .clear
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.textContainer.widthTracksTextView = true
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // ✅ 让它更愿意“纵向变高”而不是横向撑开
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
                                     
        tv.dataDetectorTypes = dataDetectorTypes
        tv.delegate = context.coordinator
        tv.isUserInteractionEnabled = true

        // ✅ 回调 & 状态塞进去（菜单标题要用）
        tv.isHighlightedBlock = isHighlighted
        tv.onToggleHighlight = onToggleHighlight
        tv.onAddNote = onAddNote
        tv.onOpenNote = onOpenNote
        tv.onOpenDictionaryLink = onOpenDictionaryLink

        // ✅ 初次渲染
        tv.attributedText = buildAttributed(text: text)

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {

        // ✅ 1) 选区存在（或正在编辑）时：不要重设 attributedText，不要动高度
        let hasSelection = tv.selectedRange.length > 0
        let isEditing = tv.isFirstResponder

        if hasSelection && isEditing {
            // 只更新回调（不影响菜单）
            if let mtv = tv as? MenuTextView {
                mtv.isHighlightedBlock = isHighlighted
                mtv.onToggleHighlight = onToggleHighlight
                mtv.onAddNote = onAddNote
                mtv.onOpenNote = onOpenNote
                mtv.onOpenDictionaryLink = onOpenDictionaryLink
            }
            // 也可以同步 isSelectable / detectorTypes（一般不需要频繁改）
            if tv.isSelectable != isSelectable { tv.isSelectable = isSelectable }
            if tv.dataDetectorTypes != dataDetectorTypes { tv.dataDetectorTypes = dataDetectorTypes }
            return
        }

        // ✅ 2) 没有选区时才允许重建富文本
        let currentSelection = tv.selectedRange

        tv.attributedText = buildAttributed(text: text)

        tv.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: tv.attributedText.length),
            actualCharacterRange: nil
        )
        tv.layoutManager.ensureLayout(for: tv.textContainer)

        tv.invalidateIntrinsicContentSize()
        tv.setNeedsLayout()

        tv.selectedRange = clampSelection(currentSelection, maxLength: tv.attributedText.length)

        // ✅ 3) 高度计算也放在“非交互中”执行，避免刷新打断菜单
        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = tv.sizeThatFits(fittingSize)
        if abs(dynamicHeight - size.height) > 0.5 {
            DispatchQueue.main.async { dynamicHeight = size.height }
        }

        if tv.isSelectable != isSelectable { tv.isSelectable = isSelectable }
        if tv.dataDetectorTypes != dataDetectorTypes { tv.dataDetectorTypes = dataDetectorTypes }

        if let mtv = tv as? MenuTextView {
            mtv.isHighlightedBlock = isHighlighted
            mtv.onToggleHighlight = onToggleHighlight
            mtv.onAddNote = onAddNote
            mtv.onOpenNote = onOpenNote
            mtv.onOpenDictionaryLink = onOpenDictionaryLink
        }
    }


    private func buildAttributed(text: String) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: textStyle)

        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byWordWrapping
        // 可选：行距更舒服
        // p.lineSpacing = 2

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: p
        ]

        let attr = NSMutableAttributedString(string: text, attributes: base)

        for span in highlightSpans {
            guard let r = clampRange(span.range, maxLength: attr.length),
                  r.length > 0 else { continue }

            attr.addAttribute(.backgroundColor,
                              value: span.color.withAlphaComponent(0.35),
                              range: r)
        }

        for r0 in annotationRanges {
            guard let r = clampRange(r0, maxLength: attr.length),
                  r.length > 0 else { continue }

            attr.addAttributes([
                .link: URL(string: "annot://\(r.location)/\(r.length)") as Any,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: UIColor.systemOrange.withAlphaComponent(0.9)
            ], range: r)
        }

        for link in dictionaryLinks {
            guard let r = clampRange(link.range, maxLength: attr.length),
                  r.length > 0,
                  let url = dictionaryLookupURL(for: link.destination) else { continue }

            attr.addAttributes([
                .link: url,
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: r)
        }

        return attr
    }

    private func dictionaryLookupURL(for word: String) -> URL? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return URL(string: "dictlookup://word/\(encoded)")
    }

    private func clampRange(_ r: NSRange, maxLength: Int) -> NSRange? {
        guard maxLength > 0 else { return nil }
        let loc = max(0, min(r.location, maxLength))
        let end = max(0, min(r.location + r.length, maxLength))
        let len = max(0, end - loc)
        guard len > 0 else { return nil }
        return NSRange(location: loc, length: len)
    }

    private func clampSelection(_ r: NSRange, maxLength: Int) -> NSRange {
        guard maxLength > 0 else { return NSRange(location: 0, length: 0) }
        let loc = max(0, min(r.location, maxLength))
        let end = max(0, min(r.location + r.length, maxLength))
        return NSRange(location: loc, length: max(0, end - loc))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var isInteracting: Binding<Bool>?
        private let showsMarkMenuActions: Bool
        private var onOpenDictionaryLink: ((String) -> Void)?
        let selectionManager: SelectionManager

        init(
            selectionManager: SelectionManager,
            isInteracting: Binding<Bool>?,
            showsMarkMenuActions: Bool,
            onOpenDictionaryLink: ((String) -> Void)?
        ) {
            self.selectionManager = selectionManager
            self.isInteracting = isInteracting
            self.showsMarkMenuActions = showsMarkMenuActions
            self.onOpenDictionaryLink = onOpenDictionaryLink
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let active = textView.selectedRange.length > 0
            DispatchQueue.main.async {
                if active {
                    self.selectionManager.activate(textView)
                } else {
                    self.selectionManager.deactivateIfCurrent(textView)
                }
            }
            
            isInteracting?.wrappedValue = textView.isFirstResponder
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isInteracting?.wrappedValue = false
        }
        
        func textView(_ textView: UITextView,
                      shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            if URL.scheme == "dictlookup" {
                let word = URL.pathComponents.dropFirst().joined(separator: "/")
                    .removingPercentEncoding?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !word.isEmpty {
                    let handler = (textView as? MenuTextView)?.onOpenDictionaryLink ?? onOpenDictionaryLink
                    handler?(word)
                }
                return false
            }

            guard URL.scheme == "annot",
                  let tv = textView as? MenuTextView else {
                return true
            }
            tv.onOpenNote?(characterRange)
            return false
        }

        // ✅ iOS 16+：把“高亮/批注”插入系统菜单
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard showsMarkMenuActions else {
                return UIMenu(children: suggestedActions)
            }

            guard range.length > 0,
                  let tv = textView as? MenuTextView else {
                return UIMenu(children: suggestedActions)
            }

            // ✅ 颜色选项（二级菜单）
            let colors: [(title: String, key: String)] = [
                ("Yellow", "yellow"),
                ("Green",  "green"),
                ("Pink",   "pink"),
                ("Blue",   "blue")
            ]

            let colorActions: [UIAction] = colors.map { item in
                UIAction(title: item.title) { _ in
                    tv.onToggleHighlight?(range, item.key)
                    tv.selectedRange = NSRange(location: range.location + range.length, length: 0)
                }
            }

            // ✅ “取消高亮”放同一个子菜单里更自然
            let highlighted = tv.isHighlightedBlock?(range) ?? false
            let removeHighlight = UIAction(
                title: "取消高亮",
                attributes: highlighted ? [] : [.disabled]
            ) { _ in
                tv.onToggleHighlight?(range, "__remove__")
                tv.selectedRange = NSRange(location: range.location + range.length, length: 0)
            }

            let highlightMenu = UIMenu(
                title: "高亮",
                options: [.displayInline],
                children: colorActions + [removeHighlight]
            )

            let note = UIAction(title: "批注") { _ in
                tv.onAddNote?(range)
                tv.selectedRange = NSRange(location: range.location + range.length, length: 0)
            }

            // 你也可以把高亮菜单放最前
            return UIMenu(children: [highlightMenu, note] + suggestedActions)
        }

    }
}

// MARK: - UITextView subclass (menu)

class MenuTextView: UITextView {
    var isHighlightedBlock: ((NSRange) -> Bool)?
    var onToggleHighlight: ((NSRange, String) -> Void)?
    var onAddNote: ((NSRange) -> Void)?
    var onOpenNote: ((NSRange) -> Void)?
    var onOpenDictionaryLink: ((String) -> Void)?
    // 闭包属性：接收外部传入的闭包，用于更新选区状态
    var setSelectionActive: ((Bool) -> Void)?
}

final class IntrinsicMenuTextView: MenuTextView {

    override func layoutSubviews() {
        super.layoutSubviews()

        // ✅ SwiftUI 下 bounds.width 经常变化，但 TextKit 不一定会自动重排
        let w = bounds.width
        guard w > 0 else { return }

        // 强制 textContainer 以当前宽度排版
        if textContainer.size.width != w {
            textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)

            // ✅ 强制 TextKit 重新排版（很关键）
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
                                           actualCharacterRange: nil)
            layoutManager.ensureLayout(for: textContainer)

            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        let w = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }
}
