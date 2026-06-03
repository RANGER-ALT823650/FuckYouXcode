//
//  WordsCollectionView.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/2.
//

import SwiftUI

struct WordsCollectionView: View {
    @EnvironmentObject private var appState: AppState

    let dictionaryService: DictionaryService

    enum CollectionKind: String, CaseIterable, Identifiable {
        case favorites = "收藏"
        case highlights = "高亮"
        case annotations = "批注"

        var id: String { rawValue }
    }

    private enum GroupCreationMode {
        case group
        case parent

        var alertTitle: String {
            switch self {
            case .group:
                return "添加组"
            case .parent:
                return "添加父组"
            }
        }

        var placeholder: String {
            switch self {
            case .group:
                return "组名"
            case .parent:
                return "父组名"
            }
        }

        var confirmTitle: String {
            switch self {
            case .group:
                return "创造"
            case .parent:
                return "创建"
            }
        }

        var message: String {
            switch self {
            case .group:
                return "创建新组，并将列表全部单词加入该组。"
            case .parent:
                return "创建一个仅用于容纳组的父组。"
            }
        }
    }

    private struct GroupDragSession {
        let group: UserDataService.WordGroupSummary
        let sourceFrame: CGRect
        var dragLocation: CGPoint?
        var translation: CGSize = .zero
        var hoveredParentID: Int64?

        var overlayFrame: CGRect {
            sourceFrame.offsetBy(dx: translation.width, dy: translation.height)
        }
    }

    private struct GroupDetailNavigationTarget: Hashable, Identifiable {
        let id: Int64
        let name: String
    }

    private typealias GroupDragGesture = SequenceGesture<LongPressGesture, DragGesture>
    private typealias GroupDragGestureValue = GroupDragGesture.Value

    private enum GroupGestureConfiguration {
        static let childDragActivationDurationWithParents: Double = 0.38
        static let dragActivationMaximumDistance: CGFloat = 12
    }

    @State private var selection: CollectionKind = .favorites
    @State private var words: [String] = []
    @State private var wordsCacheByKind: [CollectionKind: [String]] = [:]
    @State private var supplementaryTextByWord: [String: String] = [:]
    @State private var supplementaryTextCacheByKind: [CollectionKind: [String: String]] = [:]
    @State private var rootWordGroups: [UserDataService.WordGroupSummary] = []
    @State private var selectableWordGroups: [UserDataService.WordGroupSummary] = []
    @State private var isLoading = false
    @State private var hasInitialLoadCompleted = false
    @State private var showCreateGroupAlert = false
    @State private var creationMode: GroupCreationMode = .group
    @State private var newGroupName = ""
    @State private var pendingWordForGroup: String?
    @State private var showGroupPickerSheet = false
    @State private var renamingGroup: UserDataService.WordGroupSummary?
    @State private var renameDraft = ""
    @State private var showRenameGroupAlert = false
    @State private var pendingGroupDeletion: UserDataService.WordGroupSummary?
    @State private var pendingParentDeletion: UserDataService.WordGroupSummary?
    @State private var groupDragSession: GroupDragSession?
    @State private var rootGroupFrames: [Int64: CGRect] = [:]
    @State private var selectedGroupDetailTarget: GroupDetailNavigationTarget?

    private var previewService: DictionaryService {
        appState.service(for: DictionaryOption.defaultID) ?? dictionaryService
    }

    private var hasRootWords: Bool {
        !words.isEmpty
    }

    private var hasParentGroups: Bool {
        rootWordGroups.contains(where: { $0.kind == .parent })
    }

    private var hasVisibleContent: Bool {
        hasRootWords || !rootWordGroups.isEmpty
    }

    private var activeDraggedGroupID: Int64? {
        groupDragSession?.group.id
    }

    private var activeDropTargetParentID: Int64? {
        groupDragSession?.hoveredParentID
    }

    private var isGroupDragActive: Bool {
        groupDragSession != nil
    }

    private var parentGroupFrames: [Int64: CGRect] {
        rootWordGroups.reduce(into: [:]) { result, group in
            guard group.kind == .parent, let frame = rootGroupFrames[group.id] else { return }
            result[group.id] = frame
        }
    }

    private var pendingGroupDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingGroupDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingGroupDeletion = nil
                }
            }
        )
    }

    private var pendingParentDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingParentDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingParentDeletion = nil
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Picker("分类", selection: $selection) {
                ForEach(CollectionKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("Add Group", systemImage: "plus") {
                prepareCreateGroupAlert()
            }
        }
    }

    @ViewBuilder
    private var collectionContent: some View {
        if isLoading && !hasInitialLoadCompleted {
            ProgressView("加载中...")
        } else if !hasVisibleContent {
            ContentUnavailableView(
                "暂无\(selection.rawValue)",
                systemImage: "tray",
                description: Text("切换到其他分类看看。")
            )
        } else {
            List {
                ForEach(words, id: \.self) { word in
                    NavigationLink(value: word) {
                        wordRow(word)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            addWordToGroup(word)
                        } label: {
                            Label("加入组", systemImage: "folder.badge.plus")
                        }
                        .tint(.blue)
                        .disabled(selectableWordGroups.isEmpty)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await deleteWord(word) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }

                ForEach(rootWordGroups) { group in
                    if group.kind == .parent {
                        parentRow(group)
                    } else {
                        regularGroupRow(group)
                    }
                }
            }
        }
    }

    private var navigatedCollectionContent: some View {
        collectionContent
            .navigationDestination(for: String.self) { word in
                DictionaryEntryView(service: dictionaryService, word: word)
            }
            .navigationDestination(item: $selectedGroupDetailTarget) { target in
                WordCollectionDetailView(
                    dictionaryService: dictionaryService,
                    groupID: target.id,
                    groupName: target.name,
                    onArchived: {
                        Task {
                            await reloadData(for: selection, showBlockingLoader: false)
                        }
                    }
                )
            }
            .toolbar {
                navigationToolbar
            }
            .task {
                await reloadData(for: selection, showBlockingLoader: true)
                hasInitialLoadCompleted = true
            }
            .onChange(of: selection) { _, newSelection in
                words = wordsCacheByKind[newSelection] ?? words
                supplementaryTextByWord = supplementaryTextCacheByKind[newSelection] ?? [:]
                Task {
                    await reloadData(for: newSelection, showBlockingLoader: false)
                }
            }
    }

    private var presentedCollectionContent: some View {
        navigatedCollectionContent
            .sheet(isPresented: $showGroupPickerSheet) {
                groupPickerSheet
            }
            .alert(creationMode.alertTitle, isPresented: $showCreateGroupAlert) {
                TextField(creationMode.placeholder, text: $newGroupName)
                Button("取消", role: .cancel) {
                    newGroupName = ""
                }
                Button(creationMode.confirmTitle) {
                    createCurrentGroupType()
                }
            } message: {
                Text(creationMode.message)
            }
            .alert("重命名组", isPresented: $showRenameGroupAlert) {
                TextField("New Name", text: $renameDraft)
                Button("取消", role: .cancel) {
                    renamingGroup = nil
                    renameDraft = ""
                }
                Button("保存") {
                    renameGroup()
                }
            } message: {
                Text("输入新的组名。")
            }
            .alert(
                "删除组",
                isPresented: pendingGroupDeletionAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    pendingGroupDeletion = nil
                }
                Button("删除", role: .destructive) {
                    confirmDeleteGroup()
                }
            } message: {
                if let pendingGroupDeletion {
                    Text("确定要删除“\(pendingGroupDeletion.name)”吗？")
                }
            }
            .alert(
                "删除父组",
                isPresented: pendingParentDeletionAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    pendingParentDeletion = nil
                }
                Button("保留子组") {
                    confirmDeleteParent(preserveChildren: true)
                }
                Button("连子组一起删除", role: .destructive) {
                    confirmDeleteParent(preserveChildren: false)
                }
            } message: {
                if let pendingParentDeletion {
                    Text("删除“\(pendingParentDeletion.name)”时，你可以选择保留里面的子组，或把它们一并删除。")
                }
            }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    presentedCollectionContent

                    if let groupDragSession {
                        dragOverlay(for: groupDragSession, in: proxy.frame(in: .global))
                    }
                }
                .onPreferenceChange(RootWordGroupFramePreferenceKey.self) { frames in
                    rootGroupFrames = frames
                }
            }
        }
    }

    @ViewBuilder
    private func regularGroupRow(_ group: UserDataService.WordGroupSummary) -> some View {
        let isDragged = activeDraggedGroupID == group.id
        let rowLabel = WordGroupListRowContent(
            group: group,
            state: .normal
        )
        .opacity(isDragged ? 0.02 : 1)
        .background(rootGroupFrameReader(for: group.id))

        Group {
            if hasParentGroups {
                rowLabel
                    .contentShape(Rectangle())
                    .gesture(groupInteractionGesture(for: group))
            } else {
                NavigationLink {
                    WordCollectionDetailView(
                        dictionaryService: dictionaryService,
                        groupID: group.id,
                        groupName: group.name,
                        onArchived: {
                            Task {
                                await reloadData(for: selection, showBlockingLoader: false)
                            }
                        }
                    )
                } label: {
                    rowLabel
                }
            }
        }
        .allowsHitTesting(!isGroupDragActive || isDragged)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginRename(group)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingGroupDeletion = group
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func parentRow(_ group: UserDataService.WordGroupSummary) -> some View {
        NavigationLink {
            WordGroupChildrenListView(
                dictionaryService: dictionaryService,
                parentGroup: group,
                onArchived: {
                    Task {
                        await reloadData(for: selection, showBlockingLoader: false)
                    }
                }
            )
        } label: {
            WordGroupListRowContent(
                group: group,
                state: activeDropTargetParentID == group.id ? .dropTarget : .normal
            )
            .background(rootGroupFrameReader(for: group.id))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isGroupDragActive)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginRename(group)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingParentDeletion = group
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var groupPickerSheet: some View {
        NavigationStack {
            List(selectableWordGroups) { group in
                Button {
                    addPendingWord(to: group.id)
                } label: {
                    HStack {
                        Text(group.breadcrumbName)
                        Spacer()
                        Text(formattedGroupLastModifiedDate(group.lastModifiedAt))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("选择组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        pendingWordForGroup = nil
                        showGroupPickerSheet = false
                    }
                }
            }
        }
    }

    private func prepareCreateGroupAlert() {
        creationMode = hasRootWords ? .group : .parent
        newGroupName = ""
        showCreateGroupAlert = true
    }

    private func reloadData(for kind: CollectionKind, showBlockingLoader: Bool) async {
        if showBlockingLoader {
            isLoading = true
        }
        defer {
            if showBlockingLoader {
                isLoading = false
            }
        }

        let loadedWords: [String]
        switch kind {
        case .favorites:
            loadedWords = await UserDataService.shared.fetchFavoriteWords()
        case .highlights:
            loadedWords = await UserDataService.shared.fetchHighlightedWords()
        case .annotations:
            loadedWords = await UserDataService.shared.fetchAnnotatedWords()
        }

        let hiddenWords = await UserDataService.shared.fetchHiddenWordsForCollections()
        let filteredWords = loadedWords.filter { !hiddenWords.contains($0) }
        let previews = await fetchWordPreviews(for: filteredWords)
        let defaultPreviewTextByWord = makePreviewTextByWord(from: previews)

        let supplementaryText: [String: String]
        switch kind {
        case .favorites:
            supplementaryText = defaultPreviewTextByWord
        case .highlights:
            let latestHighlights = await UserDataService.shared.fetchLatestHighlightDisplayTexts(words: filteredWords)
            supplementaryText = makeHighlightSupplementaryText(
                words: filteredWords,
                latestHighlights: latestHighlights,
                fallbackPreviews: defaultPreviewTextByWord
            )
        case .annotations:
            supplementaryText = await UserDataService.shared.fetchLatestAnnotationDisplayTexts(words: filteredWords)
        }

        async let loadedRootGroups = UserDataService.shared.fetchRootWordGroups()
        async let loadedSelectableGroups = UserDataService.shared.fetchSelectableWordGroups()
        let latestRootGroups = await loadedRootGroups
        let latestSelectableGroups = await loadedSelectableGroups

        wordsCacheByKind[kind] = filteredWords
        supplementaryTextCacheByKind[kind] = supplementaryText
        if selection == kind {
            words = filteredWords
            supplementaryTextByWord = supplementaryText
        }
        rootWordGroups = latestRootGroups
        selectableWordGroups = latestSelectableGroups
    }

    private func deleteWord(_ word: String) async {
        switch selection {
        case .favorites:
            await UserDataService.shared.removeFavorite(word: word)
        case .highlights:
            await UserDataService.shared.removeHighlights(word: word)
        case .annotations:
            await UserDataService.shared.removeAnnotations(word: word)
        }

        await reloadData(for: selection, showBlockingLoader: false)
    }

    private func addWordToGroup(_ word: String) {
        guard !selectableWordGroups.isEmpty else { return }

        if selectableWordGroups.count == 1, let onlyGroup = selectableWordGroups.first {
            Task {
                await UserDataService.shared.addWord(word, toGroupID: onlyGroup.id)
                await UserDataService.shared.markWordsHiddenForCollections([word])
                await reloadData(for: selection, showBlockingLoader: false)
            }
            return
        }

        pendingWordForGroup = word
        showGroupPickerSheet = true
    }

    private func addPendingWord(to groupID: Int64) {
        guard let word = pendingWordForGroup else { return }
        pendingWordForGroup = nil
        showGroupPickerSheet = false

        Task {
            await UserDataService.shared.addWord(word, toGroupID: groupID)
            await UserDataService.shared.markWordsHiddenForCollections([word])
            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func createCurrentGroupType() {
        let name = newGroupName
        newGroupName = ""

        Task {
            switch creationMode {
            case .group:
                let allCollectionWords = await UserDataService.shared.fetchAllCollectionWordsForAddGroup()
                if await UserDataService.shared.createWordGroup(baseName: name, words: allCollectionWords) != nil {
                    await UserDataService.shared.markWordsHiddenForCollections(allCollectionWords)
                }
            case .parent:
                _ = await UserDataService.shared.createParentWordGroup(baseName: name)
            }

            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func beginRename(_ group: UserDataService.WordGroupSummary) {
        renamingGroup = group
        renameDraft = group.name
        showRenameGroupAlert = true
    }

    private func renameGroup() {
        guard let group = renamingGroup else { return }
        let newName = renameDraft
        renamingGroup = nil
        renameDraft = ""

        Task {
            _ = await UserDataService.shared.renameWordGroup(groupID: group.id, baseName: newName)
            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func confirmDeleteGroup() {
        guard let group = pendingGroupDeletion else { return }
        pendingGroupDeletion = nil

        Task {
            await UserDataService.shared.deleteWordGroupAndPurgeCollections(groupID: group.id)
            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func confirmDeleteParent(preserveChildren: Bool) {
        guard let parentGroup = pendingParentDeletion else { return }
        pendingParentDeletion = nil

        Task {
            await UserDataService.shared.deleteParentWordGroup(
                parentGroupID: parentGroup.id,
                preserveChildren: preserveChildren
            )
            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func dragOverlay(for session: GroupDragSession, in containerFrame: CGRect) -> some View {
        WordGroupListRowContent(
            group: session.group,
            state: .lifted
        )
        .frame(width: session.sourceFrame.width, alignment: .leading)
        .offset(
            x: session.overlayFrame.minX - containerFrame.minX,
            y: session.overlayFrame.minY - containerFrame.minY
        )
        .allowsHitTesting(false)
        .zIndex(10)
    }

    private func rootGroupFrameReader(for groupID: Int64) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RootWordGroupFramePreferenceKey.self,
                value: [groupID: proxy.frame(in: .global)]
            )
        }
    }

    private func groupInteractionGesture(for group: UserDataService.WordGroupSummary) -> some Gesture {
        let dragGesture = groupDragGesture()
            .onChanged { value in
                handleGroupDragChanged(value, for: group)
            }
            .onEnded { _ in
                handleGroupDragEnded(for: group)
            }

        return TapGesture()
            .exclusively(before: dragGesture)
            .onEnded { value in
                switch value {
                case .first(_):
                    navigateToGroupDetail(group)
                case .second(_):
                    break
                }
            }
    }

    private func groupDragGesture() -> GroupDragGesture {
        LongPressGesture(
            minimumDuration: GroupGestureConfiguration.childDragActivationDurationWithParents,
            maximumDistance: GroupGestureConfiguration.dragActivationMaximumDistance
        )
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
    }

    private func navigateToGroupDetail(_ group: UserDataService.WordGroupSummary) {
        selectedGroupDetailTarget = GroupDetailNavigationTarget(
            id: group.id,
            name: group.name
        )
    }

    private func handleGroupDragChanged(_ value: GroupDragGestureValue, for group: UserDataService.WordGroupSummary) {
        switch value {
        case .first(true):
            break
        case .first(false):
            break
        case .second(true, let drag):
            beginGroupDragIfNeeded(for: group)
            updateGroupDrag(for: group, with: drag)
        case .second(false, _):
            break
        }
    }

    private func beginGroupDragIfNeeded(for group: UserDataService.WordGroupSummary) {
        guard groupDragSession == nil, let sourceFrame = rootGroupFrames[group.id] else { return }
        Haptics.rigid()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            groupDragSession = GroupDragSession(group: group, sourceFrame: sourceFrame)
        }
    }

    private func updateGroupDrag(
        for group: UserDataService.WordGroupSummary,
        with dragValue: DragGesture.Value?
    ) {
        guard var session = groupDragSession, session.group.id == group.id else { return }

        if let dragValue {
            session.dragLocation = dragValue.location
            session.translation = dragValue.translation
        } else {
            session.dragLocation = nil
            session.translation = .zero
        }

        let hoverLocation = session.dragLocation ?? CGPoint(
            x: session.overlayFrame.midX,
            y: session.overlayFrame.midY
        )
        let hoveredParentID = RootWordGroupDropTargetResolver.resolve(
            location: hoverLocation,
            overlayFrame: session.overlayFrame,
            parentFrames: parentGroupFrames
        )
        if hoveredParentID != session.hoveredParentID {
            if hoveredParentID != nil {
                Haptics.selectionChanged()
            }
            session.hoveredParentID = hoveredParentID
        }

        groupDragSession = session
    }

    private func handleGroupDragEnded(for group: UserDataService.WordGroupSummary) {
        guard let session = groupDragSession, session.group.id == group.id else { return }
        if let parentGroupID = session.hoveredParentID {
            commitGroupDrag(groupID: group.id, parentGroupID: parentGroupID)
        } else {
            cancelGroupDrag()
        }
    }

    private func cancelGroupDrag() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            groupDragSession = nil
        }
    }

    private func commitGroupDrag(groupID: Int64, parentGroupID: Int64) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            groupDragSession = nil
        }

        Task {
            let didMove = await UserDataService.shared.moveWordGroup(
                groupID: groupID,
                toParentGroupID: parentGroupID
            )
            if didMove {
                await MainActor.run {
                    Haptics.success()
                }
            }
            await reloadData(for: selection, showBlockingLoader: false)
        }
    }

    private func wordRow(_ word: String) -> some View {
        HStack(spacing: 10) {
            Text(word)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if let supplementaryText = supplementaryTextByWord[word], !supplementaryText.isEmpty {
                Text(supplementaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 8)
            }
        }
    }

    private func fetchWordPreviews(for words: [String]) async -> [String: WordListPreviewRaw] {
        guard !words.isEmpty else { return [:] }
        do {
            return try await previewService.fetchWordListPreviews(words: words)
        } catch {
            return [:]
        }
    }

    private func makePreviewTextByWord(from previews: [String: WordListPreviewRaw]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(previews.count)
        for (word, preview) in previews {
            if let text = preview.compactPreviewText(posStyle: .abbreviation), !text.isEmpty {
                result[word] = text
            }
        }
        return result
    }

    private func makeHighlightSupplementaryText(
        words: [String],
        latestHighlights: [String: String],
        fallbackPreviews: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(words.count)

        for word in words {
            if let highlightText = latestHighlights[word], !highlightText.isEmpty {
                result[word] = highlightText
                continue
            }

            if let fallbackText = fallbackPreviews[word], !fallbackText.isEmpty {
                result[word] = fallbackText
            }
        }

        return result
    }
}

struct WordGroupChildrenListView: View {
    @Environment(\.dismiss) private var dismiss

    let dictionaryService: DictionaryService
    let parentGroup: UserDataService.WordGroupSummary
    let includeArchivedChildren: Bool
    let allowsArchiving: Bool
    let onArchived: (() -> Void)?

    init(
        dictionaryService: DictionaryService,
        parentGroup: UserDataService.WordGroupSummary,
        includeArchivedChildren: Bool = false,
        allowsArchiving: Bool = true,
        onArchived: (() -> Void)? = nil
    ) {
        self.dictionaryService = dictionaryService
        self.parentGroup = parentGroup
        self.includeArchivedChildren = includeArchivedChildren
        self.allowsArchiving = allowsArchiving
        self.onArchived = onArchived
    }

    @State private var childGroups: [UserDataService.WordGroupSummary] = []
    @State private var isLoading = false
    @State private var hasInitialLoadCompleted = false
    @State private var renamingGroup: UserDataService.WordGroupSummary?
    @State private var renameDraft = ""
    @State private var showRenameAlert = false
    @State private var showArchiveConfirmation = false
    @State private var pendingDeletion: UserDataService.WordGroupSummary?

    var body: some View {
        Group {
            if isLoading && !hasInitialLoadCompleted {
                ProgressView("加载中...")
            } else if childGroups.isEmpty {
                ContentUnavailableView(
                    "暂无子组",
                    systemImage: "tray",
                    description: Text("创建或收纳子组后，会显示在这里。")
                )
            } else {
                List(childGroups) { group in
                    NavigationLink {
                        WordCollectionDetailView(
                            dictionaryService: dictionaryService,
                            groupID: group.id,
                            groupName: group.name,
                            allowsArchiving: allowsArchiving,
                            onArchived: {
                                Task {
                                    await reloadChildGroups(showBlockingLoader: false)
                                }
                            }
                        )
                    } label: {
                        WordGroupListRowContent(
                            group: group,
                            state: .normal
                        )
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            beginRename(group)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = group
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(parentGroup.name)
        .toolbar {
            if allowsArchiving {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("归档", systemImage: "archivebox") {
                        showArchiveConfirmation = true
                    }
                }
            }
        }
        .task {
            guard !hasInitialLoadCompleted else { return }
            await reloadChildGroups(showBlockingLoader: true)
            hasInitialLoadCompleted = true
        }
        .alert("归档父组", isPresented: $showArchiveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("归档", role: .destructive) {
                archiveParentGroup()
            }
        } message: {
            Text("归档后会从“集”的列表中移除，可在设置里的“归档”中查看。")
        }
        .alert("重命名组", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameDraft)
            Button("取消", role: .cancel) {
                renamingGroup = nil
                renameDraft = ""
            }
            Button("保存") {
                renameGroup()
            }
        } message: {
            Text("输入新的组名。")
        }
        .alert(
            "删除组",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletion = nil
                    }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                confirmDeleteGroup()
            }
        } message: {
            if let pendingDeletion {
                Text("确定要删除“\(pendingDeletion.name)”吗？")
            }
        }
    }

    private func reloadChildGroups(showBlockingLoader: Bool) async {
        if showBlockingLoader {
            isLoading = true
        }
        defer {
            if showBlockingLoader {
                isLoading = false
            }
        }

        childGroups = await UserDataService.shared.fetchChildWordGroups(
            parentGroupID: parentGroup.id,
            includeArchivedChildren: includeArchivedChildren
        )
    }

    private func beginRename(_ group: UserDataService.WordGroupSummary) {
        renamingGroup = group
        renameDraft = group.name
        showRenameAlert = true
    }

    private func renameGroup() {
        guard let group = renamingGroup else { return }
        let newName = renameDraft
        renamingGroup = nil
        renameDraft = ""

        Task {
            _ = await UserDataService.shared.renameWordGroup(groupID: group.id, baseName: newName)
            await reloadChildGroups(showBlockingLoader: false)
        }
    }

    private func confirmDeleteGroup() {
        guard let group = pendingDeletion else { return }
        pendingDeletion = nil

        Task {
            await UserDataService.shared.deleteWordGroupAndPurgeCollections(groupID: group.id)
            await reloadChildGroups(showBlockingLoader: false)
        }
    }

    private func archiveParentGroup() {
        Task {
            let didArchive = await UserDataService.shared.archiveWordGroup(groupID: parentGroup.id)
            guard didArchive else { return }
            await MainActor.run {
                onArchived?()
                dismiss()
            }
        }
    }
}

private struct WordGroupListRowContent: View {
    enum State: Equatable {
        case normal
        case lifted
        case dropTarget
    }

    let group: UserDataService.WordGroupSummary
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.blue)
            Text(group.name)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 10)
            Text(formattedGroupLastModifiedDate(group.lastModifiedAt))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .shadow(
            color: shadowColor,
            radius: shadowRadius,
            x: 0,
            y: shadowYOffset
        )
        .offset(y: verticalOffset)
        .zIndex(state == .lifted ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: state)
    }

    private var backgroundColor: Color {
        switch state {
        case .normal:
            return .clear
        case .lifted:
            return Color(uiColor: .secondarySystemBackground).opacity(0.96)
        case .dropTarget:
            return Color(uiColor: .secondarySystemBackground).opacity(0.84)
        }
    }

    private var borderColor: Color {
        switch state {
        case .normal:
            return .clear
        case .lifted:
            return Color.white.opacity(0.08)
        case .dropTarget:
            return Color.blue.opacity(0.18)
        }
    }

    private var borderWidth: CGFloat {
        switch state {
        case .normal:
            return 0
        case .lifted:
            return 0.5
        case .dropTarget:
            return 1
        }
    }

    private var scale: CGFloat {
        switch state {
        case .normal:
            return 1
        case .lifted:
            return 1.024
        case .dropTarget:
            return 1.01
        }
    }

    private var opacity: Double {
        switch state {
        case .normal:
            return 1
        case .lifted:
            return 0.94
        case .dropTarget:
            return 0.98
        }
    }

    private var shadowColor: Color {
        switch state {
        case .normal:
            return .clear
        case .lifted:
            return Color.black.opacity(0.14)
        case .dropTarget:
            return Color.black.opacity(0.08)
        }
    }

    private var shadowRadius: CGFloat {
        switch state {
        case .normal:
            return 0
        case .lifted:
            return 18
        case .dropTarget:
            return 12
        }
    }

    private var shadowYOffset: CGFloat {
        switch state {
        case .normal:
            return 0
        case .lifted:
            return 12
        case .dropTarget:
            return 6
        }
    }

    private var verticalOffset: CGFloat {
        switch state {
        case .normal:
            return 0
        case .lifted:
            return -2
        case .dropTarget:
            return 0
        }
    }
}

private struct RootWordGroupFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum RootWordGroupDropTargetResolver {
    static func resolve(
        location: CGPoint,
        overlayFrame: CGRect,
        parentFrames: [Int64: CGRect]
    ) -> Int64? {
        let orderedFrames = parentFrames.sorted { lhs, rhs in
            lhs.value.midY < rhs.value.midY
        }

        if let directHit = orderedFrames.first(where: { adjustedFrame($0.value).contains(location) }) {
            return directHit.key
        }

        let overlayMidpoint = CGPoint(x: overlayFrame.midX, y: overlayFrame.midY)
        if let centeredHit = orderedFrames.first(where: { adjustedFrame($0.value).contains(overlayMidpoint) }) {
            return centeredHit.key
        }

        return orderedFrames
            .compactMap { entry -> (id: Int64, area: CGFloat)? in
                let overlap = adjustedFrame(entry.value).intersection(overlayFrame)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                return (entry.key, overlap.width * overlap.height)
            }
            .max(by: { $0.area < $1.area })?
            .id
    }

    private static func adjustedFrame(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: -8, dy: -6)
    }
}

private func formattedGroupLastModifiedDate(_ timestamp: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let currentYear = calendar.component(.year, from: Date())

    if year == currentYear {
        return "\(day)/\(month)"
    }
    return "\(year)/\(month)/\(day)"
}

#Preview {
    Text("WordsCollectionView Preview")
}
