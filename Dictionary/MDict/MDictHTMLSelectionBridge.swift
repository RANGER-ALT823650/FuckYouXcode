import CoreGraphics
import Foundation

nonisolated enum MDictResourcePath {
    static func makeEntryURL(dictionaryID: String, entryKey: String) -> URL? {
        let encodedDictionaryID = encodePathComponent(dictionaryID)
        let encodedEntryKey = encodePathComponent(entryKey)
        return URL(string: "dict://entry/\(encodedDictionaryID)/\(encodedEntryKey)/")
    }

    static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func resolveAssetPath(
        requestURL: URL,
        dictionaryID: String,
        currentEntryKey: String
    ) -> String? {
        let host = requestURL.host?.lowercased() ?? ""
        let components = pathComponents(from: requestURL)

        switch host {
        case "asset":
            if let first = components.first,
               first == dictionaryID {
                return canonicalPath(components.dropFirst().joined(separator: "/"))
            }
            return canonicalPath(components.joined(separator: "/"))

        case "entry":
            guard let first = components.first else { return nil }
            if first != dictionaryID {
                return canonicalPath(components.joined(separator: "/"))
            }

            if components.count == 2,
               decoded(components[1]) == currentEntryKey {
                return nil
            }

            if components.count >= 3,
               decoded(components[1]) == currentEntryKey {
                return canonicalPath(components.dropFirst(2).joined(separator: "/"))
            }

            return canonicalPath(components.dropFirst().joined(separator: "/"))

        default:
            return nil
        }
    }

    static func canonicalPath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "" }

        let decodedPath = decoded(rawPath)
            .replacingOccurrences(of: "\\", with: "/")

        let parts = decodedPath.split(separator: "/", omittingEmptySubsequences: true)

        var normalized: [String] = []
        normalized.reserveCapacity(parts.count)

        for partSub in parts {
            let part = String(partSub)
            if part == "." || part.isEmpty {
                continue
            }

            if part == ".." {
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
                continue
            }

            normalized.append(part)
        }

        return normalized.joined(separator: "/")
    }

    static func normalizedLookupPath(_ rawPath: String) -> String {
        canonicalPath(rawPath).lowercased()
    }

    private static func pathComponents(from url: URL) -> [String] {
        url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

nonisolated struct MDictHTMLBridgeHighlight: Codable, Hashable {
    let start: Int
    let length: Int
    let color: String
}

nonisolated struct MDictHTMLBridgeAnnotation: Codable, Hashable {
    let start: Int
    let length: Int
}

nonisolated struct MDictHTMLMarksPayload: Codable, Hashable {
    let field: String
    let highlights: [MDictHTMLBridgeHighlight]
    let annotations: [MDictHTMLBridgeAnnotation]

    static let empty = MDictHTMLMarksPayload(field: "", highlights: [], annotations: [])
}

nonisolated struct MDictHTMLSelectionPayload: Codable {
    let start: Int
    let length: Int
    let text: String?
    let rect: MDictHTMLSelectionRect?
}

nonisolated struct MDictHTMLSelectionRect: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum MDictHTMLSelectionBridge {
    static let bridgeObjectName = "__mdictSelectionBridge"
    static let selectionMessageName = "mdictSelectionDidChange"
    static let annotationMessageName = "mdictAnnotationDidTap"

    static let bootstrapScript = """
    (function() {
      if (window.\(bridgeObjectName)) { return; }

      const messageNames = {
        selection: "\(selectionMessageName)",
        annotation: "\(annotationMessageName)"
      };

      const state = {
        suppressSelection: false,
        interactionActive: false
      };

      const STYLE_IDS = {
        highlight: "mdict-mark-highlight",
        annotation: "mdict-mark-annotation"
      };

      function installStyles() {
        if (!document.getElementById(STYLE_IDS.highlight)) {
          const style = document.createElement("style");
          style.id = STYLE_IDS.highlight;
          style.textContent = `
            html, body { -webkit-touch-callout: none; }
            span[data-mdict-mark="1"] { border-radius: 2px; }
          `;
          document.head.appendChild(style);
        }
      }

      function colorForKey(colorKey) {
        switch ((colorKey || "").toLowerCase()) {
          case "green":
            return "rgba(52, 199, 89, 0.35)";
          case "pink":
            return "rgba(255, 45, 85, 0.30)";
          case "blue":
            return "rgba(0, 122, 255, 0.30)";
          case "yellow":
          default:
            return "rgba(255, 214, 10, 0.35)";
        }
      }

      function postMessage(name, body) {
        try {
          const handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers[name];
          if (handler && typeof handler.postMessage === "function") {
            handler.postMessage(body);
          }
        } catch (_) {}
      }

      function textNodes(root) {
        if (!root) { return []; }
        const walker = document.createTreeWalker(
          root,
          NodeFilter.SHOW_TEXT,
          {
            acceptNode(node) {
              if (!node || !node.nodeValue || node.nodeValue.length === 0) {
                return NodeFilter.FILTER_REJECT;
              }
              const parent = node.parentElement;
              if (!parent) {
                return NodeFilter.FILTER_REJECT;
              }
              const tag = parent.tagName;
              if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") {
                return NodeFilter.FILTER_REJECT;
              }
              return NodeFilter.FILTER_ACCEPT;
            }
          }
        );

        const nodes = [];
        let current;
        while ((current = walker.nextNode())) {
          nodes.push(current);
        }
        return nodes;
      }

      function bodyTextLength() {
        return textNodes(document.body).reduce((sum, node) => sum + node.nodeValue.length, 0);
      }

      function clampRange(start, length, totalLength) {
        if (!Number.isFinite(start) || !Number.isFinite(length)) { return null; }
        if (length <= 0 || totalLength <= 0) { return null; }
        const s = Math.max(0, Math.min(start, totalLength));
        const e = Math.max(0, Math.min(start + length, totalLength));
        if (e <= s) { return null; }
        return { start: s, length: e - s };
      }

      function normalizeMarks(payload, totalLength) {
        const highlights = Array.isArray(payload && payload.highlights) ? payload.highlights : [];
        const annotations = Array.isArray(payload && payload.annotations) ? payload.annotations : [];

        const normalizedHighlights = highlights
          .map(item => clampRange(Number(item.start), Number(item.length), totalLength))
          .map((range, index) => {
            if (!range) { return null; }
            return {
              start: range.start,
              length: range.length,
              color: String((highlights[index] && highlights[index].color) || "yellow")
            };
          })
          .filter(Boolean);

        const normalizedAnnotations = annotations
          .map(item => clampRange(Number(item.start), Number(item.length), totalLength))
          .filter(Boolean);

        return {
          highlights: normalizedHighlights,
          annotations: normalizedAnnotations
        };
      }

      function unwrapMarks() {
        const marks = Array.from(document.querySelectorAll('span[data-mdict-mark="1"]'));
        for (const mark of marks) {
          const parent = mark.parentNode;
          if (!parent) { continue; }
          while (mark.firstChild) {
            parent.insertBefore(mark.firstChild, mark);
          }
          parent.removeChild(mark);
          parent.normalize();
        }
      }

      function locateBoundary(globalOffset) {
        const nodes = textNodes(document.body);
        if (nodes.length === 0) { return null; }

        let offset = globalOffset;
        for (const node of nodes) {
          const length = node.nodeValue.length;
          if (offset <= length) {
            return { node, offset };
          }
          offset -= length;
        }

        const last = nodes[nodes.length - 1];
        return { node: last, offset: last.nodeValue.length };
      }

      function wrapRange(segment) {
        const startPos = locateBoundary(segment.start);
        const endPos = locateBoundary(segment.start + segment.length);
        if (!startPos || !endPos) { return; }

        const range = document.createRange();
        try {
          range.setStart(startPos.node, startPos.offset);
          range.setEnd(endPos.node, endPos.offset);
        } catch (_) {
          return;
        }

        if (range.collapsed) { return; }

        const span = document.createElement("span");
        span.setAttribute("data-mdict-mark", "1");

        if (segment.color) {
          span.style.backgroundColor = colorForKey(segment.color);
        }

        if (Number.isFinite(segment.annotationStart) && Number.isFinite(segment.annotationLength)) {
          span.style.textDecoration = "underline";
          span.style.textDecorationColor = "rgba(255, 149, 0, 0.95)";
          span.style.textDecorationThickness = "2px";
          span.dataset.annotationStart = String(segment.annotationStart);
          span.dataset.annotationLength = String(segment.annotationLength);
        }

        const extracted = range.extractContents();
        span.appendChild(extracted);
        range.insertNode(span);
      }

      function segmentMarks(marks, totalLength) {
        const boundaries = new Set([0, totalLength]);

        for (const item of marks.highlights) {
          boundaries.add(item.start);
          boundaries.add(item.start + item.length);
        }
        for (const item of marks.annotations) {
          boundaries.add(item.start);
          boundaries.add(item.start + item.length);
        }

        const sorted = Array.from(boundaries).sort((a, b) => a - b);
        const segments = [];

        for (let i = 0; i + 1 < sorted.length; i += 1) {
          const start = sorted[i];
          const end = sorted[i + 1];
          if (end <= start) { continue; }

          const highlight = marks.highlights.find(item => item.start <= start && (item.start + item.length) >= end);
          const annotation = marks.annotations.find(item => item.start <= start && (item.start + item.length) >= end);
          if (!highlight && !annotation) { continue; }

          segments.push({
            start: start,
            length: end - start,
            color: highlight ? highlight.color : null,
            annotationStart: annotation ? annotation.start : null,
            annotationLength: annotation ? annotation.length : null
          });
        }

        return segments;
      }

      function applyMarks(payload) {
        installStyles();
        unwrapMarks();

        const totalLength = bodyTextLength();
        if (totalLength <= 0) { return; }

        const normalized = normalizeMarks(payload || {}, totalLength);
        const segments = segmentMarks(normalized, totalLength);
        for (const segment of segments) {
          wrapRange(segment);
        }
      }

      function currentSelection() {
        const selection = window.getSelection();
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
          return null;
        }

        const range = selection.getRangeAt(0);
        if (!document.body || !document.body.contains(range.commonAncestorContainer)) {
          return null;
        }

        const pre = document.createRange();
        pre.selectNodeContents(document.body);
        pre.setEnd(range.startContainer, range.startOffset);

        const start = pre.toString().length;
        const length = range.toString().length;
        if (length <= 0) { return null; }

        const rects = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
        const sourceRect = rects.length > 0 ? rects[0] : range.getBoundingClientRect();
        const viewport = window.visualViewport;
        const scale = viewport && Number.isFinite(viewport.scale) ? viewport.scale : 1;
        const offsetLeft = viewport && Number.isFinite(viewport.offsetLeft) ? viewport.offsetLeft : 0;
        const offsetTop = viewport && Number.isFinite(viewport.offsetTop) ? viewport.offsetTop : 0;
        const rect = sourceRect
          ? {
              x: (sourceRect.left - offsetLeft) * scale,
              y: (sourceRect.top - offsetTop) * scale,
              width: sourceRect.width * scale,
              height: sourceRect.height * scale
            }
          : null;

        return { start, length, text: range.toString(), rect };
      }

      let selectionTimer = null;
      function scheduleSelectionEmit(delay) {
        if (selectionTimer) {
          clearTimeout(selectionTimer);
        }
        selectionTimer = setTimeout(emitSelectionIfNeeded, delay);
      }

      function emitSelectionIfNeeded() {
        if (state.suppressSelection) { return; }
        const payload = currentSelection();
        if (!payload) { return; }
        postMessage(messageNames.selection, payload);
      }

      document.addEventListener("selectionchange", function() {
        if (state.interactionActive) { return; }
        scheduleSelectionEmit(120);
      });

      document.addEventListener("touchstart", function() {
        state.interactionActive = true;
      }, true);

      document.addEventListener("touchend", function() {
        state.interactionActive = false;
        scheduleSelectionEmit(120);
      }, true);

      document.addEventListener("touchcancel", function() {
        state.interactionActive = false;
      }, true);

      document.addEventListener("pointerdown", function() {
        state.interactionActive = true;
      }, true);

      document.addEventListener("pointerup", function() {
        state.interactionActive = false;
        scheduleSelectionEmit(80);
      }, true);

      document.addEventListener("mouseup", function() {
        state.interactionActive = false;
        scheduleSelectionEmit(80);
      }, true);

      document.addEventListener("contextmenu", function(event) {
        event.preventDefault();
      }, true);

      document.addEventListener("click", function(event) {
        const target = event.target && event.target.closest
          ? event.target.closest('span[data-mdict-mark="1"][data-annotation-start][data-annotation-length]')
          : null;
        if (!target) { return; }

        const start = Number(target.dataset.annotationStart);
        const length = Number(target.dataset.annotationLength);
        if (!Number.isFinite(start) || !Number.isFinite(length) || length <= 0) { return; }

        postMessage(messageNames.annotation, { start, length });
        event.preventDefault();
        event.stopPropagation();
      }, true);

      window.\(bridgeObjectName) = {
        applyMarks(payload) {
          try {
            applyMarks(payload || {});
          } catch (_) {}
        },
        clearSelection() {
          state.suppressSelection = true;
          try {
            const selection = window.getSelection();
            if (selection) {
              selection.removeAllRanges();
            }
          } catch (_) {}

          setTimeout(function() {
            state.suppressSelection = false;
          }, 80);
        }
      };
    })();
    """
}
