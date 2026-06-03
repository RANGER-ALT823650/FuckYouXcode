import Foundation
import SwiftUI
import UIKit
import WebKit

struct MDictHTMLView: UIViewRepresentable {
    private static let bottomContentPadding: CGFloat = 112

    let dictionaryID: String
    let entryKey: String
    let entryHTML: String
    let service: DictionaryService
    let sourceFolderURL: URL?
    let mdxRelativePath: String?
    let entryID: Int64
    let markField: String
    let highlights: [MDictHTMLBridgeHighlight]
    let annotations: [MDictHTMLBridgeAnnotation]
    let clearSelectionToken: Int
    let onSelectionChange: ((MDictHTMLSelectionPayload) -> Void)?
    let onAnnotationTap: ((NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(dictionaryID: dictionaryID)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = configuration.userContentController
        contentController.addUserScript(
            WKUserScript(
                source: MDictHTMLSelectionBridge.bootstrapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let messageProxy = ScriptMessageProxy()
        messageProxy.coordinator = context.coordinator
        contentController.add(messageProxy, name: MDictHTMLSelectionBridge.selectionMessageName)
        contentController.add(messageProxy, name: MDictHTMLSelectionBridge.annotationMessageName)

        let schemeHandler = MDictAssetSchemeHandler(
            dictionaryID: dictionaryID,
            service: service,
            currentEntrySnapshot: {
                context.coordinator.currentEntrySnapshot
            },
            currentResourceSnapshot: {
                context.coordinator.currentResourceSnapshot
            }
        )
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "dict")

        let webView = MDictWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset.bottom = Self.bottomContentPadding
        webView.scrollView.verticalScrollIndicatorInsets.bottom = Self.bottomContentPadding
        webView.backgroundColor = .clear
        webView.isOpaque = false

        context.coordinator.schemeHandler = schemeHandler
        context.coordinator.scriptMessageProxy = messageProxy
        context.coordinator.webView = webView
        context.coordinator.updateResourceSnapshot(
            sourceFolderURL: sourceFolderURL,
            mdxRelativePath: mdxRelativePath
        )
        context.coordinator.updateInteraction(
            entryID: entryID,
            markField: markField,
            highlights: highlights,
            annotations: annotations,
            clearSelectionToken: clearSelectionToken,
            onSelectionChange: onSelectionChange,
            onAnnotationTap: onAnnotationTap
        )
        context.coordinator.update(entryKey: entryKey, html: normalizedDocument(from: entryHTML), forceReload: true)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.scrollView.contentInset.bottom = Self.bottomContentPadding
        uiView.scrollView.verticalScrollIndicatorInsets.bottom = Self.bottomContentPadding

        context.coordinator.webView = uiView
        context.coordinator.updateResourceSnapshot(
            sourceFolderURL: sourceFolderURL,
            mdxRelativePath: mdxRelativePath
        )
        context.coordinator.updateInteraction(
            entryID: entryID,
            markField: markField,
            highlights: highlights,
            annotations: annotations,
            clearSelectionToken: clearSelectionToken,
            onSelectionChange: onSelectionChange,
            onAnnotationTap: onAnnotationTap
        )
        context.coordinator.update(entryKey: entryKey, html: normalizedDocument(from: entryHTML), forceReload: false)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        let contentController = uiView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: MDictHTMLSelectionBridge.selectionMessageName)
        contentController.removeScriptMessageHandler(forName: MDictHTMLSelectionBridge.annotationMessageName)
        contentController.removeAllUserScripts()

        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.webView = nil
        coordinator.scriptMessageProxy = nil
    }

    private func normalizedDocument(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "<html><body></body></html>"
        }

        if trimmed.range(of: "<html", options: [.caseInsensitive, .regularExpression]) != nil {
            return trimmed
        }

        return """
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
          </head>
          <body>
            \(trimmed)
          </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let dictionaryID: String
        weak var webView: WKWebView?
        var schemeHandler: MDictAssetSchemeHandler?
        var scriptMessageProxy: ScriptMessageProxy?

        private(set) var currentEntrySnapshot: (entryKey: String, html: String) = ("", "")
        private(set) var currentResourceSnapshot: (sourceFolderURL: URL?, mdxRelativePath: String?) = (nil, nil)
        private(set) var currentMarkContext: (entryID: Int64, field: String) = (0, "")
        private var loadedSnapshot: (entryKey: String, htmlHash: Int)?
        private var marksPayload: MDictHTMLMarksPayload = .empty
        private var currentClearSelectionToken: Int = 0
        private var onSelectionChange: ((MDictHTMLSelectionPayload) -> Void)?
        private var onAnnotationTap: ((NSRange) -> Void)?
        private var lastForwardedSelection: NSRange?

        init(dictionaryID: String) {
            self.dictionaryID = dictionaryID
        }

        func update(entryKey: String, html: String, forceReload: Bool) {
            currentEntrySnapshot = (entryKey, html)

            guard let webView else { return }
            let htmlHash = html.hashValue
            let newSnapshot = (entryKey: entryKey, htmlHash: htmlHash)

            if !forceReload,
               let loadedSnapshot,
               loadedSnapshot.entryKey == newSnapshot.entryKey,
               loadedSnapshot.htmlHash == newSnapshot.htmlHash {
                return
            }

            loadedSnapshot = newSnapshot

            guard let url = MDictResourcePath.makeEntryURL(dictionaryID: dictionaryID, entryKey: entryKey) else {
                return
            }

            webView.load(URLRequest(url: url))
        }

        func updateResourceSnapshot(sourceFolderURL: URL?, mdxRelativePath: String?) {
            currentResourceSnapshot = (sourceFolderURL, mdxRelativePath)
        }

        func updateInteraction(
            entryID: Int64,
            markField: String,
            highlights: [MDictHTMLBridgeHighlight],
            annotations: [MDictHTMLBridgeAnnotation],
            clearSelectionToken: Int,
            onSelectionChange: ((MDictHTMLSelectionPayload) -> Void)?,
            onAnnotationTap: ((NSRange) -> Void)?
        ) {
            currentMarkContext = (entryID, markField)
            self.onSelectionChange = onSelectionChange
            self.onAnnotationTap = onAnnotationTap

            let payload = MDictHTMLMarksPayload(
                field: markField,
                highlights: highlights,
                annotations: annotations
            )

            if marksPayload != payload {
                marksPayload = payload
                applyMarksIfPossible()
            }

            if clearSelectionToken != currentClearSelectionToken {
                currentClearSelectionToken = clearSelectionToken
                clearSelectionIfPossible()
                lastForwardedSelection = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyMarksIfPossible()
        }

        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView,
            willPresentEditMenuWithAnimator animator: any UIEditMenuInteractionAnimating
        ) {
            (webView as? MDictWebView)?.dismissNativeEditMenu()
        }

        func handleScriptMessage(_ message: WKScriptMessage) {
            switch message.name {
            case MDictHTMLSelectionBridge.selectionMessageName:
                guard let payload = decodeSelectionPayload(from: message.body),
                      payload.length > 0 else {
                    return
                }

                let range = NSRange(location: payload.start, length: payload.length)
                if lastForwardedSelection == range {
                    return
                }
                lastForwardedSelection = range
                onSelectionChange?(payload)

            case MDictHTMLSelectionBridge.annotationMessageName:
                guard let payload = decodeSelectionPayload(from: message.body),
                      payload.length > 0 else {
                    return
                }
                onAnnotationTap?(NSRange(location: payload.start, length: payload.length))

            default:
                return
            }
        }

        private func decodeSelectionPayload(from body: Any) -> MDictHTMLSelectionPayload? {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let payload = try? JSONDecoder().decode(MDictHTMLSelectionPayload.self, from: data) else {
                return nil
            }
            return payload
        }

        private func applyMarksIfPossible() {
            guard let webView else { return }
            guard let data = try? JSONEncoder().encode(marksPayload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }

            let bridge = MDictHTMLSelectionBridge.bridgeObjectName
            let js = "window.\(bridge) && window.\(bridge).applyMarks(\(json));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func clearSelectionIfPossible() {
            guard let webView else { return }
            let bridge = MDictHTMLSelectionBridge.bridgeObjectName
            let js = "window.\(bridge) && window.\(bridge).clearSelection();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.handleScriptMessage(message)
        }
    }
}

final class MDictWebView: WKWebView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        [
            UIMenu.Identifier.standardEdit,
            .lookup,
            .share,
            .replace,
            .textStyle,
            .spelling,
            .substitutions,
            .transformations,
            .speech
        ].forEach { builder.remove(menu: $0) }
    }

    func dismissNativeEditMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if #available(iOS 16.0, *) {
                self.dismissEditMenuInteractions(in: self)
            } else {
                UIMenuController.shared.hideMenu()
            }
        }
    }

    @available(iOS 16.0, *)
    private func dismissEditMenuInteractions(in view: UIView) {
        for interaction in view.interactions {
            (interaction as? UIEditMenuInteraction)?.dismissMenu()
        }

        for subview in view.subviews {
            dismissEditMenuInteractions(in: subview)
        }
    }
}
