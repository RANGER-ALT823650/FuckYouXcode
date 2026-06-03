import SwiftUI
import AVFoundation
import Combine
import UIKit

nonisolated struct DictionaryInlineLink: Equatable, Sendable {
    let range: NSRange
    let word: String
}

nonisolated struct DictionaryInlineLinkParseResult: Equatable, Sendable {
    let displayText: String
    let links: [DictionaryInlineLink]
}

nonisolated enum DictionaryInlineLinkParser {
    static func parse(_ rawText: String) -> DictionaryInlineLinkParseResult {
        var displayText = ""
        var links: [DictionaryInlineLink] = []
        var cursor = rawText.startIndex

        while let openingRange = rawText.range(of: "[[", range: cursor..<rawText.endIndex) {
            displayText.append(contentsOf: rawText[cursor..<openingRange.lowerBound])

            let linkContentStart = openingRange.upperBound
            guard let closingRange = rawText.range(of: "]]", range: linkContentStart..<rawText.endIndex) else {
                displayText.append(contentsOf: rawText[openingRange.lowerBound..<rawText.endIndex])
                return DictionaryInlineLinkParseResult(displayText: displayText, links: links)
            }

            let rawWord = String(rawText[linkContentStart..<closingRange.lowerBound])
            let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)

            if word.isEmpty || word.contains("[[") || word.contains("]]") {
                displayText.append(contentsOf: rawText[openingRange.lowerBound..<closingRange.upperBound])
            } else {
                let start = (displayText as NSString).length
                displayText.append(word)
                let length = (word as NSString).length
                links.append(DictionaryInlineLink(range: NSRange(location: start, length: length), word: word))
            }

            cursor = closingRange.upperBound
        }

        displayText.append(contentsOf: rawText[cursor..<rawText.endIndex])
        return DictionaryInlineLinkParseResult(displayText: displayText, links: links)
    }
}

struct DictionaryEntryView: View {
    private static let importedHTMLField = "html_body"

    @EnvironmentObject private var appState: AppState

    let service: DictionaryService
    let word: String
    
    @State private var entries: [DictionaryEntry] = []
    @State private var errorMessage: String?
    @State private var isFavorite = false
    
    // 批注弹窗
    @State private var showNoteSheet = false
    @State private var noteDraft = ""
    @State private var pendingNoteRange: NSRange? = nil
    @State private var pendingNoteEntryID: Int64?   // ✅ 新增
    @State private var pendingNoteField: String = "definition" // ✅ 新增（后面可扩展到其他列）
    @State private var editingAnnotationID: Int64?
    @State private var originalNoteDraft = ""
    
    @State private var highlightsByEntry: [Int64: [UserDataService.Highlight]] = [:]
    @State private var annotationsByEntry: [Int64: [UserDataService.Annotation]] = [:]
    @State private var showImportDictionarySheet = false
    @State private var showAIChatSheet = false
    @State private var importedSelectionRange: NSRange?
    @State private var importedSelectionText: String?
    @State private var importedSelectionMenuRect: CGRect?
    @State private var showImportedSelectionActions = false
    @State private var importedClearSelectionToken = 0
    @State private var inlineDictionaryLinkDestination: InlineDictionaryLinkDestination?

    @StateObject private var selectionManager = SelectionManager()

    private var activeDictionaryService: DictionaryService {
        appState.service(for: appState.selectedDictionaryID) ?? service
    }

    private var activeDictionaryID: String {
        appState.selectedDictionaryID
    }

    private var activeDictionaryOption: DictionaryOption? {
        appState.option(for: activeDictionaryID)
    }

    private var activeSourceFolderURL: URL? {
        appState.sourceFolderURL(for: activeDictionaryID)
    }

    private var activeMDXRelativePath: String? {
        activeDictionaryOption?.mdxFileName
    }

    private var canRebuildActiveDictionary: Bool {
        guard let activeDictionaryOption else { return false }
        return activeDictionaryOption.sourceKind == .imported
            && activeDictionaryOption.status != .indexing
    }

    private var shouldRenderImportedHTML: Bool {
        guard activeDictionaryOption?.sourceKind == .imported else { return false }
        return entries.contains(where: { entry in
            guard let html = entry.html else { return false }
            return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private var importedPrimaryEntry: DictionaryEntry? {
        entries.first(where: { entry in
            guard let html = entry.html else { return false }
            return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private var importedEntryID: Int64? {
        importedPrimaryEntry?.id
    }

    private var importedSelectionIsHighlighted: Bool {
        guard let range = importedSelectionRange,
              let entryID = importedEntryID else {
            return false
        }
        return highlights(for: entryID, field: Self.importedHTMLField).contains { highlight in
            highlight.start == range.location && highlight.length == range.length
        }
    }

    private var shouldShowLegacyRelatedSection: Bool {
        !entries.contains { entry in
            guard let origination = entry.origination, !origination.isEmpty else {
                return false
            }
            return !DictionaryInlineLinkParser.parse(origination).links.isEmpty
        }
    }
    
    
    var body: some View {
        Group {
            if shouldRenderImportedHTML,
               let entry = importedPrimaryEntry,
               let html = entry.html,
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ZStack(alignment: .topTrailing) {
                    MDictHTMLView(
                        dictionaryID: activeDictionaryID,
                        entryKey: entry.word,
                        entryHTML: html,
                        service: activeDictionaryService,
                        sourceFolderURL: activeSourceFolderURL,
                        mdxRelativePath: activeMDXRelativePath,
                        entryID: entry.id,
                        markField: Self.importedHTMLField,
                        highlights: importedBridgeHighlights(for: entry.id),
                        annotations: importedBridgeAnnotations(for: entry.id),
                        clearSelectionToken: importedClearSelectionToken,
                        onSelectionChange: { payload in
                            importedSelectionRange = NSRange(location: payload.start, length: payload.length)
                            importedSelectionText = normalizedSelectionText(payload.text)
                            importedSelectionMenuRect = payload.rect?.cgRect
                            withAnimation(.easeOut(duration: 0.14)) {
                                showImportedSelectionActions = true
                            }
                        },
                        onAnnotationTap: { range in
                            let importedAnnotations = annotations(for: entry.id, field: Self.importedHTMLField)
                            if let note = annotation(for: range, in: importedAnnotations) {
                                presentNoteSheet(
                                    range: range,
                                    entryID: entry.id,
                                    field: Self.importedHTMLField,
                                    annotation: note
                                )
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .bottom)

                    if showImportedSelectionActions {
                        importedSelectionOverlay
                            .zIndex(2)
                    }

                    favoriteToggleButton
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .zIndex(3)
                }
            } else {
                standardEntryContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                aiChatButton
                dictionaryMenu
            }
        }
        .environmentObject(selectionManager)
        .simultaneousGesture(
            TapGesture().onEnded {
                if selectionManager.hasSelection {
                    selectionManager.clearSelection()
                }
            }
        )
        .sheet(isPresented: $showNoteSheet) { noteSheet
            .presentationBackground(.background)
            .presentationDetents([.medium, .large])}
        .sheet(isPresented: $showImportDictionarySheet) {
            FolderPickerSheet(isPresented: $showImportDictionarySheet) { folderURL in
                Task {
                    await appState.importDictionary(folderURL: folderURL)
                }
            }
        }
        .sheet(isPresented: $showAIChatSheet) {
            AIChatSheetView(contextWord: word)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: showImportedSelectionActions) { _, isPresented in
            guard !isPresented else { return }
            importedSelectionRange = nil
            importedSelectionText = nil
            importedSelectionMenuRect = nil
            importedClearSelectionToken += 1
        }
        .onChange(of: appState.selectedDictionaryID) { _, _ in
            Task { await loadAll() }
        }
        .navigationDestination(item: $inlineDictionaryLinkDestination) { destination in
            DictionaryEntryView(service: activeDictionaryService, word: destination.word)
        }
    }

    private var importedSelectionOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showImportedSelectionActions = false
                        }
                    }

                ImportedSelectionActionMenu(
                    isHighlighted: importedSelectionIsHighlighted,
                    onHighlight: { colorKey in
                        setImportedHighlight(colorKey: colorKey)
                    },
                    onRemoveHighlight: {
                        removeImportedHighlight()
                    },
                    onNote: {
                        beginImportedAnnotation()
                    }
                )
                .position(importedSelectionMenuPosition(in: proxy.size))
            }
        }
    }

    private func importedSelectionMenuPosition(in size: CGSize) -> CGPoint {
        let menuSize = ImportedSelectionActionMenu.preferredSize
        let margin: CGFloat = 12
        let rect = importedSelectionMenuRect ?? CGRect(
            x: size.width / 2,
            y: 96,
            width: 0,
            height: 0
        )

        let minX = (menuSize.width / 2) + margin
        let maxX = max(minX, size.width - (menuSize.width / 2) - margin)
        let x = min(max(rect.midX, minX), maxX)

        let topY = rect.minY - (menuSize.height / 2) - 9
        let bottomY = rect.maxY + (menuSize.height / 2) + 12
        let lowerBound = (menuSize.height / 2) + margin
        let upperBound = max(lowerBound, size.height - (menuSize.height / 2) - margin)
        let preferredY = bottomY <= upperBound ? bottomY : topY
        let y = min(max(preferredY, lowerBound), upperBound)

        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private var standardEntryContent: some View {
        Group {
            if !entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        Divider().padding(.vertical, 4)

                        let grouped = Dictionary(grouping: entries) { ($0.pos?.isEmpty == false ? $0.pos! : "other") }
                        let posOrder = ["verb","noun","adjective","adverb","pronoun","preposition","conjunction","interjection","determiner","numeral","phrase","other"]
                        let sortedKeys = grouped.keys.sorted { (posOrder.firstIndex(of: $0) ?? 999) < (posOrder.firstIndex(of: $1) ?? 999) }

                        ForEach(sortedKeys, id: \.self) { key in
                            posSection(key, entries: grouped[key] ?? [])
                            if key != sortedKeys.last { Divider().padding(.vertical, 8) }
                        }

                        relatedSection
                    }
                    .padding()
                }
            } else if let errorMessage {
                centeredStatusView(
                    systemName: "exclamationmark.book.closed",
                    title: errorMessage
                )
            } else {
                emptyLookupPromptView
            }
        }
    }

    private var emptyLookupPromptView: some View {
        ZStack {
            Color.clear

            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("词典中没有“\(word)”")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text("建议使用 AI 搜索")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showAIChatSheet = true
                } label: {
                    Label("用 AI 搜索", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func centeredStatusView(systemName: String, title: String) -> some View {
        ZStack {
            Color.clear

            VStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    @ViewBuilder
    private var dictionaryMenu: some View {
        Menu {
            ForEach(appState.dictionaryOptions) { option in
                Button {
                    appState.selectDictionary(id: option.id)
                } label: {
                    if option.id == activeDictionaryID {
                        Label(option.localizedDisplayName, systemImage: "checkmark")
                    } else {
                        Text(option.localizedDisplayName)
                    }
                }
                .disabled(!option.status.isSelectable)
            }

            Divider()

            Button {
                showImportDictionarySheet = true
            } label: {
                Label("添加词典", systemImage: "plus")
            }

            Button {
                Task {
                    await appState.rebuildIndex(for: activeDictionaryID)
                }
            } label: {
                Label("重建词典索引", systemImage: "arrow.clockwise")
            }
            .disabled(!canRebuildActiveDictionary)
        } label: {
            Image(systemName: "books.vertical")
        }
    }

    private var aiChatButton: some View {
        Button {
            showAIChatSheet = true
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("AI 对话")
    }
    
    
    private func splitExamples(_ examples: String) -> [String] {
        examples
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func extractEnglish(_ line: String) -> String {
        // 你的分隔符是 " — "（注意空格），如果不稳定就用 "—"
        if let idx = line.range(of: "—") {
            return line[..<idx.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }
    
    private func parseHWD(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func reloadUserMarks() async {
        let highlights = await UserDataService.shared.fetchHighlights(
            word: word,
            dictionaryID: activeDictionaryID
        )

        let annotations = await UserDataService.shared.fetchAnnotations(
            word: word,
            dictionaryID: activeDictionaryID
        )

        highlightsByEntry = Dictionary(grouping: highlights) { $0.entry_id }

        annotationsByEntry = Dictionary(grouping: annotations) { $0.entry_id }
    }

    @ViewBuilder
    private var header: some View{
        // 顶部只显示一次“单词
            if let first = entries.first {
                HStack{
                    VStack(alignment: .leading){
                        Text(first.word)
                            .font(.largeTitle.bold())
                            .tracking(1)     // 字间距稍微拉开
                        Spacer()
                        if let lemma = first.lemma, lemma != first.word {
                            NavigationLink(lemma){
                                DictionaryEntryView(service: activeDictionaryService, word: lemma)
                            }
                            .font(.subheadline)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                    VStack{
                        if let frequency = first.frequency {
                            Text("Frequency: \(frequency)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        if let lvl = first.level {
                            Text("level: \(lvl)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                    }
                    
                    
                    favoriteToggleButton
                }
            
                HStack{
                    if let pho = first.phonetic, !pho.isEmpty {
                        selectableFieldText(pho, entryID: first.id, field: "phonetic")
                    }
                    SpeakButton(text: first.word, rate: 0.50).buttonStyle(.plain)
                    AccentPicker()
                        .padding(.trailing, 6)
                }
        }
    }

    private func posSection(_ key: String, entries: [DictionaryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(key).font(.headline).padding(.top, 4)

            ForEach(entries) { entry in
                entryBlock(entry, in: key, all: entries)
            }
        }
    }
    
    @ViewBuilder
    private func entryBlock(_ entry: DictionaryEntry, in key: String, all: [DictionaryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let def = entry.definition, !def.isEmpty {
                selectableFieldText(def, entryID: entry.id, field: "definition")
            }

            if let idioms = entry.idioms, !idioms.isEmpty {
                selectableFieldText(idioms, entryID: entry.id, field: "idioms")
            }

            examplesView(entry.examples, entryID: entry.id)

            if let ori = entry.origination, !ori.isEmpty {
                originationText(ori, entryID: entry.id)
            }

            if entry.id != all.last?.id { Divider().opacity(0.4) }
        }
    }
    
    private func uiColor(from s: String) -> UIColor {
        switch s.lowercased() {
        case "yellow": return .systemYellow
        case "green":  return .systemGreen
        case "pink":   return .systemPink
        case "blue":   return .systemBlue
        default:       return .systemYellow
        }
    }

    @ViewBuilder
    private var favoriteToggleButton: some View {
        Button {
            Task {
                do {
                    isFavorite = try await UserDataService.shared.toggleFavorite(word: word)
                } catch {
                    print("toggleFavorite failed:", error.localizedDescription)
                }
            }
            Haptics.rigid()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
        }
        .font(.title)
        .scaleEffect(isFavorite ? 1.2 : 1.0)
        .animation(.spring(), value: isFavorite)
    }
    
    private func highlights(for entryID: Int64, field: String) -> [UserDataService.Highlight] {
        (highlightsByEntry[entryID] ?? []).filter { $0.field == field }
    }
    
    private func annotations(for entryID: Int64, field: String) -> [UserDataService.Annotation] {
        (annotationsByEntry[entryID] ?? []).filter { $0.field == field }
    }
    
    private func annotation(
        for range: NSRange,
        in annotations: [UserDataService.Annotation]
    ) -> UserDataService.Annotation? {
        annotations.first { a in
            guard let s = a.start, let l = a.length else { return false }
            return s == range.location && l == range.length
        }
    }
    
    @ViewBuilder
    private func selectableFieldText(
        _ text: String,
        entryID: Int64,
        field: String,
        style: UIFont.TextStyle = .body,
        color: UIColor = .label,
        dictionaryLinks: [SelectableTextLink] = []
    ) -> some View {
        let textLen = (text as NSString).length
        let fieldHighlights = highlights(for: entryID, field: field)
        let fieldAnnotations = annotations(for: entryID, field: field)
        
        let spans: [HighlightSpan] = fieldHighlights
            .filter { $0.start >= 0 && $0.length > 0 && ($0.start + $0.length) <= textLen }
            .map { h in
                HighlightSpan(
                    range: NSRange(location: h.start, length: h.length),
                    color: uiColor(from: h.color)
                )
            }
        
        let noteRanges: [NSRange] = fieldAnnotations.compactMap { a in
            guard let s = a.start, let l = a.length, l > 0 else { return nil }
            guard s >= 0 && (s + l) <= textLen else { return nil }
            return NSRange(location: s, length: l)
        }
        
        SelectableText(
            text: text,
            textStyle: style,
            textColor: color,
            highlightSpans: spans,
            annotationRanges: noteRanges,
            dictionaryLinks: dictionaryLinks,
            isHighlighted: { range in
                fieldHighlights.contains { h in
                    h.start == range.location && h.length == range.length
                }
            },
            onToggleHighlight: { range, colorKey in
                Task {
                    if colorKey == "__remove__" {
                        await UserDataService.shared.removeHighlight(
                            word: word,
                            dictionaryID: activeDictionaryID,
                            entry_id: entryID,
                            field: field,
                            start: range.location,
                            length: range.length
                        )
                    } else {
                        let snippet = normalizedSelectionText((text as NSString).substring(with: range)) ?? ""
                        await UserDataService.shared.setHighlight(
                            word: word,
                            dictionaryID: activeDictionaryID,
                            entry_id: entryID,
                            field: field,
                            start: range.location,
                            length: range.length,
                            color: colorKey,
                            note: snippet
                        )
                    }
                    await reloadUserMarks()
                }
            },
            onAddNote: { range in
                let existing = annotation(for: range, in: fieldAnnotations)
                presentNoteSheet(
                    range: range,
                    entryID: entryID,
                    field: field,
                    annotation: existing
                )
            },
            onOpenNote: { range in
                let existing = annotation(for: range, in: fieldAnnotations)
                presentNoteSheet(
                    range: range,
                    entryID: entryID,
                    field: field,
                    annotation: existing
                )
            },
            onOpenDictionaryLink: { linkedWord in
                inlineDictionaryLinkDestination = InlineDictionaryLinkDestination(word: linkedWord)
            }
        )
    }

    private func originationText(_ rawText: String, entryID: Int64) -> some View {
        let parsed = DictionaryInlineLinkParser.parse(rawText)
        let links = parsed.links.map { link in
            SelectableTextLink(range: link.range, destination: link.word)
        }

        return selectableFieldText(
            parsed.displayText,
            entryID: entryID,
            field: "origination",
            dictionaryLinks: links
        )
    }

    @ViewBuilder
    private func examplesView(_ examplesText: String?, entryID: Int64) -> some View {
        if let examplesText, !examplesText.isEmpty {
            let lines = splitExamples(examplesText)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    let en = extractEnglish(line)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        selectableFieldText(line, entryID: entryID, field: "examples_\(idx)")

                        if !en.isEmpty {
                            SpeakButton(text: en, rate: 0.50)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var relatedSection: some View {
        if shouldShowLegacyRelatedSection,
           let first = entries.first,
           let raw = first.hwd,
           !raw.isEmpty {

            let words = parseHWD(raw)
            if !words.isEmpty {
                Divider().padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Related").font(.headline)
                    ForEach(words, id: \.self) { w in
                        NavigationLink(w) {
                            DictionaryEntryView(service: activeDictionaryService, word: w)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
    
    private func loadAll() async {
        do {
            entries = try await activeDictionaryService.lookupEntries(word, allowsFallbacks: false)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = "词典暂不可用"
            print("Dictionary lookup failed for '\(word)': \(error.localizedDescription)")
        }
        await reloadUserMarks()
        isFavorite = await UserDataService.shared.isFavorite(word: word)
    }

    private func importedBridgeHighlights(for entryID: Int64) -> [MDictHTMLBridgeHighlight] {
        highlights(for: entryID, field: Self.importedHTMLField)
            .filter { $0.start >= 0 && $0.length > 0 }
            .map { highlight in
                MDictHTMLBridgeHighlight(
                    start: highlight.start,
                    length: highlight.length,
                    color: highlight.color
                )
            }
    }

    private func importedBridgeAnnotations(for entryID: Int64) -> [MDictHTMLBridgeAnnotation] {
        annotations(for: entryID, field: Self.importedHTMLField)
            .compactMap { annotation in
                guard let start = annotation.start,
                      let length = annotation.length,
                      start >= 0,
                      length > 0 else {
                    return nil
                }
                return MDictHTMLBridgeAnnotation(start: start, length: length)
            }
    }

    private func setImportedHighlight(colorKey: String) {
        guard let range = importedSelectionRange,
              let entryID = importedEntryID else {
            showImportedSelectionActions = false
            return
        }

        showImportedSelectionActions = false
        Task {
            await UserDataService.shared.setHighlight(
                word: word,
                dictionaryID: activeDictionaryID,
                entry_id: entryID,
                field: Self.importedHTMLField,
                start: range.location,
                length: range.length,
                color: colorKey,
                note: importedSelectionText ?? ""
            )
            await reloadUserMarks()
        }
    }

    private func removeImportedHighlight() {
        guard let range = importedSelectionRange,
              let entryID = importedEntryID else {
            showImportedSelectionActions = false
            return
        }

        showImportedSelectionActions = false
        Task {
            await UserDataService.shared.removeHighlight(
                word: word,
                dictionaryID: activeDictionaryID,
                entry_id: entryID,
                field: Self.importedHTMLField,
                start: range.location,
                length: range.length
            )
            await reloadUserMarks()
        }
    }

    private func beginImportedAnnotation() {
        guard let range = importedSelectionRange,
              let entryID = importedEntryID else {
            showImportedSelectionActions = false
            return
        }

        let importedAnnotations = annotations(for: entryID, field: Self.importedHTMLField)
        presentNoteSheet(
            range: range,
            entryID: entryID,
            field: Self.importedHTMLField,
            annotation: annotation(for: range, in: importedAnnotations)
        )
        showImportedSelectionActions = false
    }

    private func presentNoteSheet(
        range: NSRange,
        entryID: Int64,
        field: String,
        annotation: UserDataService.Annotation?
    ) {
        pendingNoteRange = range
        pendingNoteEntryID = entryID
        pendingNoteField = field
        editingAnnotationID = annotation?.id
        noteDraft = annotation?.content ?? ""
        originalNoteDraft = annotation?.content ?? ""
        showNoteSheet = true
    }

    private func deleteEditingAnnotation() {
        let trimmedDraft = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }

        Task {
            if let annotationID = editingAnnotationID {
                await UserDataService.shared.removeAnnotation(id: annotationID)
                await reloadUserMarks()
            }
            showNoteSheet = false
        }
    }
    
    @ViewBuilder
    private var noteSheet: some View{
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $noteDraft)
                    .frame(minHeight: 180)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                
                Spacer()
            }
            .padding()
            .navigationTitle("批注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("删除") {
                        deleteEditingAnnotation()
                    }
                    .foregroundStyle(.red)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            let trimmedDraft = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let r = pendingNoteRange,
                                  let eid = pendingNoteEntryID,
                                  !trimmedDraft.isEmpty else {
                                showNoteSheet = false
                                return
                            }

                            if let annotationID = editingAnnotationID {
                                let trimmedOriginal = originalNoteDraft
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                guard trimmedDraft != trimmedOriginal else {
                                    showNoteSheet = false
                                    return
                                }
                                await UserDataService.shared.removeAnnotation(id: annotationID)
                            }

                            await UserDataService.shared.addAnnotation(
                                word: word,
                                dictionaryID: activeDictionaryID,
                                entry_id: eid,
                                field: pendingNoteField,
                                start: r.location,
                                length: r.length,
                                content: noteDraft
                            )
                            showNoteSheet = false
                            await reloadUserMarks()
                        }
                    }
                }
            }
        }
    }

    private func normalizedSelectionText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }
    
}

private struct ImportedSelectionActionMenu: View {
    static let preferredSize = CGSize(width: 316, height: 44)

    let isHighlighted: Bool
    let onHighlight: (String) -> Void
    let onRemoveHighlight: () -> Void
    let onNote: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ImportedSelectionMenuItem("Yellow") { onHighlight("yellow") }
            ImportedSelectionMenuSeparator()
            ImportedSelectionMenuItem("Green") { onHighlight("green") }
            ImportedSelectionMenuSeparator()
            ImportedSelectionMenuItem("Pink") { onHighlight("pink") }
            ImportedSelectionMenuSeparator()
            ImportedSelectionMenuItem("Blue") { onHighlight("blue") }
            ImportedSelectionMenuSeparator()

            Menu {
                Button("批注", action: onNote)
                Button("取消高亮", role: .destructive, action: onRemoveHighlight)
                    .disabled(!isHighlighted)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .padding(.trailing, 4)
            }
            .menuOrder(.fixed)
        }
        .font(.system(size: 19, weight: .regular))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.48))
            }
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 9, x: 0, y: 4)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct ImportedSelectionMenuItem: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ImportedSelectionMenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 24)
    }
}


final class TTSPlayer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSPlayer()

    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // 播放前：开启 duck（压低背景音）+ 静音键也能出声
    private func activateDuckingSession() {
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession activate error:", error)
        }
    }

    // 播放后：恢复（让背景音回到原音量）
    // 方案A：deactivate（最常见、恢复最干净）
    private func deactivateSession() {
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("AudioSession deactivate error:", error)
        }
    }

    func speak(_ text: String, locale: String = "en-US", rate: Float = 0.50) {
        activateDuckingSession()

        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: locale)
        u.rate = rate
        u.volume = 1.0

        // 避免 .immediate 造成某些机型/系统上状态异常
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        synthesizer.speak(u)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deactivateSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        deactivateSession()
    }
}

private struct InlineDictionaryLinkDestination: Identifiable, Hashable {
    let word: String

    var id: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

    
    final class SpeechSettings: ObservableObject {
        enum Accent: String, CaseIterable, Identifiable {
            case us = "en-US"
            case uk = "en-GB"
            
            var id: String { rawValue }
            var title: String { self == .us ? "US" : "UK" }
            var flag: String { self == .us ? "🇺🇸" : "🇬🇧" }
        }
        
        @AppStorage("tts_accent") private var storedAccent: String = Accent.us.rawValue
        
        @Published var accent: Accent = .us {
            didSet { storedAccent = accent.rawValue }
        }
        
        init() {
            accent = Accent(rawValue: storedAccent) ?? .us
        }
    }
    
    struct AccentPicker: View {
        @EnvironmentObject var speech: SpeechSettings
        
        var body: some View {
            Picker("", selection: $speech.accent) {
                ForEach(SpeechSettings.Accent.allCases) { accent in
                    Text("\(accent.flag) \(accent.title)")
                        .tag(accent)
                }
            }
            .pickerStyle(.segmented)
        }
    }

struct SpeakButton: View {
    @EnvironmentObject var speech: SpeechSettings
    let text: String
    var rate: Float = 0.50
    
    var body: some View {
        Button {
            TTSPlayer.shared.speak(text, locale: speech.accent.rawValue, rate: rate)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .padding()
        }
        
    }
}


    
    
    
    
