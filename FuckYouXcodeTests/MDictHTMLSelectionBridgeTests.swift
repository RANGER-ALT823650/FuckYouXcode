import Foundation
import Testing
import UIKit
import WebKit
@testable import FuckYouXcode

struct MDictHTMLSelectionBridgeTests {
    @Test func entryURLUsesDictSchemeAndTrailingSlash() {
        let url = MDictResourcePath.makeEntryURL(dictionaryID: "dict.id", entryKey: "run")
        #expect(url?.absoluteString == "dict://entry/dict.id/run/")
    }

    @Test func resolvesRelativeAssetPathsWithEntryBase() {
        let request = URL(string: "dict://entry/dictA/run/images/icon.png")!
        let path = MDictResourcePath.resolveAssetPath(
            requestURL: request,
            dictionaryID: "dictA",
            currentEntryKey: "run"
        )

        #expect(path == "images/icon.png")
    }

    @Test func resolvesParentSegmentsAndKeepsSubdirectories() {
        let request = URL(string: "dict://entry/dictA/Media/Icon.PNG")!
        let path = MDictResourcePath.resolveAssetPath(
            requestURL: request,
            dictionaryID: "dictA",
            currentEntryKey: "run"
        )

        #expect(path == "Media/Icon.PNG")
        #expect(MDictResourcePath.normalizedLookupPath(path ?? "") == "media/icon.png")
    }

    @Test func hostAssetPathSupportsDictionaryPrefixAndCaseFold() {
        let request = URL(string: "dict://asset/dictA/CSS/Main.CSS")!
        let path = MDictResourcePath.resolveAssetPath(
            requestURL: request,
            dictionaryID: "dictA",
            currentEntryKey: "run"
        )

        #expect(path == "CSS/Main.CSS")
        #expect(MDictResourcePath.normalizedLookupPath(path ?? "") == "css/main.css")
    }

    @Test func entryRequestReturnsNilAssetPathForDocumentLoad() {
        let request = URL(string: "dict://entry/dictA/run/")!
        let path = MDictResourcePath.resolveAssetPath(
            requestURL: request,
            dictionaryID: "dictA",
            currentEntryKey: "run"
        )

        #expect(path == nil)
    }

    @Test func directoryResolverAddsMdxBaseCandidate() {
        let candidates = DirectoryAssetResolver.candidateRelativePaths(
            requestedPath: "assets/site.css",
            mdxRelativePath: "dict/main.mdx"
        )

        #expect(candidates == ["assets/site.css", "dict/assets/site.css"])
    }

    @Test func bootstrapScriptSuppressesNativeWebKitCallout() {
        #expect(MDictHTMLSelectionBridge.bootstrapScript.contains("-webkit-touch-callout: none"))
        #expect(MDictHTMLSelectionBridge.bootstrapScript.contains("contextmenu"))
        #expect(MDictHTMLSelectionBridge.bootstrapScript.contains("touchend"))
        #expect(MDictHTMLSelectionBridge.bootstrapScript.contains("pointerup"))
        #expect(MDictHTMLSelectionBridge.bootstrapScript.contains("visualViewport"))
    }

    @Test func selectionPayloadDecodesSelectionRect() throws {
        let data = """
        {
          "start": 3,
          "length": 4,
          "text": "word",
          "rect": { "x": 10, "y": 20, "width": 30, "height": 40 }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(MDictHTMLSelectionPayload.self, from: data)

        #expect(payload.start == 3)
        #expect(payload.length == 4)
        #expect(payload.rect?.cgRect == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @MainActor
    @Test func mdictWebViewSuppressesNativeEditActions() {
        let webView = MDictWebView(frame: .zero, configuration: WKWebViewConfiguration())

        #expect(webView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) == false)
    }
}
