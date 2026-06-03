import Foundation
import UniformTypeIdentifiers
import WebKit

struct DirectoryAssetPayload {
    let originalPath: String
    let mimeType: String
    let data: Data
}

enum DirectoryAssetResolver {
    static func loadAsset(
        sourceFolderURL: URL,
        requestedPath: String,
        mdxRelativePath: String?
    ) -> DirectoryAssetPayload? {
        let normalizedRequested = sanitizeRelativePath(requestedPath)
        guard !normalizedRequested.isEmpty else { return nil }

        let candidates = candidateRelativePaths(
            requestedPath: normalizedRequested,
            mdxRelativePath: mdxRelativePath
        )

        for candidate in candidates {
            if let exact = loadExact(sourceFolderURL: sourceFolderURL, relativePath: candidate) {
                return exact
            }

            if let folded = loadCaseInsensitive(sourceFolderURL: sourceFolderURL, relativePath: candidate) {
                return folded
            }
        }

        return nil
    }

    static func candidateRelativePaths(requestedPath: String, mdxRelativePath: String?) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        let canonicalRequested = sanitizeRelativePath(requestedPath)
        if !canonicalRequested.isEmpty, seen.insert(canonicalRequested).inserted {
            ordered.append(canonicalRequested)
        }

        if let mdxRelativePath {
            let mdxBase = (mdxRelativePath as NSString).deletingLastPathComponent
            if !mdxBase.isEmpty {
                let prefixedRaw = "\(mdxBase)/\(canonicalRequested)"
                let prefixed = sanitizeRelativePath(prefixedRaw)
                if !prefixed.isEmpty, seen.insert(prefixed).inserted {
                    ordered.append(prefixed)
                }
            }
        }

        return ordered
    }

    static func sanitizeRelativePath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let unified = decoded.replacingOccurrences(of: "\\", with: "/")
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true)

        var normalized: [String] = []
        normalized.reserveCapacity(parts.count)

        for partSub in parts {
            let part = String(partSub)

            if part == "." || part.isEmpty {
                continue
            }

            if part == ".." {
                guard !normalized.isEmpty else {
                    return ""
                }
                normalized.removeLast()
                continue
            }

            normalized.append(part)
        }

        return normalized.joined(separator: "/")
    }

    static func isPathWithinRoot(_ fileURL: URL, rootURL: URL) -> Bool {
        let standardizedRoot = rootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let standardizedFile = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        if standardizedFile == standardizedRoot {
            return true
        }

        return standardizedFile.hasPrefix(standardizedRoot + "/")
    }

    private static func loadExact(sourceFolderURL: URL, relativePath: String) -> DirectoryAssetPayload? {
        guard let fileURL = safeFileURL(sourceFolderURL: sourceFolderURL, relativePath: relativePath) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        return DirectoryAssetPayload(
            originalPath: relativePath,
            mimeType: mimeType(forPath: relativePath),
            data: data
        )
    }

    private static func loadCaseInsensitive(sourceFolderURL: URL, relativePath: String) -> DirectoryAssetPayload? {
        guard let fileURL = resolveCaseInsensitiveFileURL(sourceFolderURL: sourceFolderURL, relativePath: relativePath) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let resolvedRootPath = sourceFolderURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let resolvedFilePath = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let prefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        guard resolvedFilePath.hasPrefix(prefix) else {
            return nil
        }
        let resolvedRelativePath = String(resolvedFilePath.dropFirst(prefix.count))

        return DirectoryAssetPayload(
            originalPath: resolvedRelativePath,
            mimeType: mimeType(forPath: resolvedRelativePath),
            data: data
        )
    }

    private static func safeFileURL(sourceFolderURL: URL, relativePath: String) -> URL? {
        let sanitized = sanitizeRelativePath(relativePath)
        guard !sanitized.isEmpty else { return nil }

        let candidate = sourceFolderURL
            .appendingPathComponent(sanitized, isDirectory: false)
            .standardizedFileURL

        guard isPathWithinRoot(candidate, rootURL: sourceFolderURL.standardizedFileURL) else {
            return nil
        }

        return candidate
    }

    private static func resolveCaseInsensitiveFileURL(sourceFolderURL: URL, relativePath: String) -> URL? {
        let sanitized = sanitizeRelativePath(relativePath)
        guard !sanitized.isEmpty else { return nil }

        let fm = FileManager.default
        let components = sanitized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }

        var currentURL = sourceFolderURL.standardizedFileURL

        for component in components {
            guard let children = try? fm.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            if let exact = children.first(where: { $0.lastPathComponent == component }) {
                guard isPathWithinRoot(exact, rootURL: sourceFolderURL) else {
                    return nil
                }
                currentURL = exact
                continue
            }

            guard let folded = children.first(where: { $0.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame }) else {
                return nil
            }
            guard isPathWithinRoot(folded, rootURL: sourceFolderURL) else {
                return nil
            }
            currentURL = folded
        }

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: currentURL.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            return nil
        }

        guard isPathWithinRoot(currentURL, rootURL: sourceFolderURL.standardizedFileURL) else {
            return nil
        }

        return currentURL
    }

    private static func mimeType(forPath path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }
}

final class MDictAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let dictionaryID: String
    private let service: DictionaryService
    private let currentEntrySnapshot: () -> (entryKey: String, html: String)
    private let currentResourceSnapshot: () -> (sourceFolderURL: URL?, mdxRelativePath: String?)

    init(
        dictionaryID: String,
        service: DictionaryService,
        currentEntrySnapshot: @escaping () -> (entryKey: String, html: String),
        currentResourceSnapshot: @escaping () -> (sourceFolderURL: URL?, mdxRelativePath: String?)
    ) {
        self.dictionaryID = dictionaryID
        self.service = service
        self.currentEntrySnapshot = currentEntrySnapshot
        self.currentResourceSnapshot = currentResourceSnapshot
    }

    static func resolveAssetBlob(
        path: String,
        sourceFolderURL: URL?,
        mdxRelativePath: String?,
        service: DictionaryService
    ) throws -> DictionaryAssetBlob? {
        if let sourceFolderURL,
           let localAsset = DirectoryAssetResolver.loadAsset(
            sourceFolderURL: sourceFolderURL,
            requestedPath: path,
            mdxRelativePath: mdxRelativePath
           ) {
            return DictionaryAssetBlob(
                originalKey: localAsset.originalPath,
                mimeType: localAsset.mimeType,
                data: localAsset.data
            )
        }

        return try service.fetchAsset(path: path)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let snapshot = currentEntrySnapshot()
        let resourceSnapshot = currentResourceSnapshot()
        let requestURL = urlSchemeTask.request.url

        guard let requestURL else {
            finish(urlSchemeTask, data: Data("Bad request".utf8), mimeType: "text/plain")
            return
        }

        do {
            if let entryKey = requestedEntryKeyIfAny(from: requestURL) {
                let preferAsset = shouldPreferAssetLookup(
                    request: urlSchemeTask.request,
                    candidate: entryKey
                )

                if preferAsset,
                   let asset = try Self.resolveAssetBlob(
                    path: entryKey,
                    sourceFolderURL: resourceSnapshot.sourceFolderURL,
                    mdxRelativePath: resourceSnapshot.mdxRelativePath,
                    service: service
                   ) {
                    finish(urlSchemeTask, data: asset.data, mimeType: asset.mimeType)
                    return
                }

                if entryKey.caseInsensitiveCompare(snapshot.entryKey) == .orderedSame {
                    finish(urlSchemeTask, data: Data(snapshot.html.utf8), mimeType: "text/html")
                    return
                }

                if let resolved = try service.fetchEntryHTML(entryKey: entryKey) {
                    finish(urlSchemeTask, data: Data(resolved.utf8), mimeType: "text/html")
                    return
                }

                if !preferAsset,
                   let fallbackAsset = try Self.resolveAssetBlob(
                    path: entryKey,
                    sourceFolderURL: resourceSnapshot.sourceFolderURL,
                    mdxRelativePath: resourceSnapshot.mdxRelativePath,
                    service: service
                   ) {
                    finish(urlSchemeTask, data: fallbackAsset.data, mimeType: fallbackAsset.mimeType)
                    return
                }

                let html = "<html><body><p>Entry not found: \(entryKey)</p></body></html>"
                finish(urlSchemeTask, data: Data(html.utf8), mimeType: "text/html")
                return
            }

            if let assetPath = MDictResourcePath.resolveAssetPath(
                requestURL: requestURL,
                dictionaryID: dictionaryID,
                currentEntryKey: snapshot.entryKey
            ), !assetPath.isEmpty,
               let asset = try Self.resolveAssetBlob(
                path: assetPath,
                sourceFolderURL: resourceSnapshot.sourceFolderURL,
                mdxRelativePath: resourceSnapshot.mdxRelativePath,
                service: service
               ) {
                finish(urlSchemeTask, data: asset.data, mimeType: asset.mimeType)
                return
            }

            let message = "Resource not found: \(requestURL.absoluteString)"
            print("Warning:", message)
            fail(urlSchemeTask, code: 404, message: message)
        } catch {
            let message = "Error: \(error.localizedDescription)"
            print("Warning:", message)
            fail(urlSchemeTask, code: 500, message: message)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // no-op
    }

    private func requestedEntryKeyIfAny(from url: URL) -> String? {
        guard (url.host ?? "").caseInsensitiveCompare("entry") == .orderedSame else {
            return nil
        }

        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if components.count == 2, components[0] == dictionaryID {
            return components[1].removingPercentEncoding ?? components[1]
        }

        if components.count == 1, let first = components.first {
            return first.removingPercentEncoding ?? first
        }

        return nil
    }

    private func shouldPreferAssetLookup(request: URLRequest, candidate: String) -> Bool {
        if candidate.contains(".") {
            return true
        }

        let accept = request
            .value(forHTTPHeaderField: "Accept")?
            .lowercased() ?? ""

        if accept.isEmpty {
            return false
        }

        let resourceHints = [
            "text/css",
            "image/",
            "audio/",
            "video/",
            "font/",
            "javascript"
        ]

        return resourceHints.contains { accept.contains($0) }
    }

    private func finish(_ task: WKURLSchemeTask, data: Data, mimeType: String) {
        let response = URLResponse(
            url: task.request.url ?? URL(string: "dict://entry")!,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int, message: String) {
        let error = Self.makeSchemeError(
            code: code,
            message: message,
            requestURL: task.request.url
        )
        task.didFailWithError(error)
    }

    static func makeSchemeError(code: Int, message: String, requestURL: URL?) -> NSError {
        NSError(
            domain: "MDictAssetSchemeHandler",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSURLErrorKey: requestURL as Any
            ]
        )
    }
}
