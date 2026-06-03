//
//  WordCollectionDetailView.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/18.
//

import SwiftUI
import UIKit
import Photos

struct WordCollectionDetailView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var photoPermissionStore = SharedPhotoLibraryPermissionStore.shared

    let dictionaryService: DictionaryService
    let groupID: Int64
    let groupName: String
    let allowsArchiving: Bool
    let onArchived: (() -> Void)?

    init(
        dictionaryService: DictionaryService,
        groupID: Int64,
        groupName: String,
        allowsArchiving: Bool = true,
        onArchived: (() -> Void)? = nil
    ) {
        self.dictionaryService = dictionaryService
        self.groupID = groupID
        self.groupName = groupName
        self.allowsArchiving = allowsArchiving
        self.onArchived = onArchived
    }

    @State private var words: [String] = []
    @State private var wordPreviews: [String: WordListPreviewRaw] = [:]
    @State private var isLoading = false
    @State private var hasInitialLoadCompleted = false

    @State private var noteText = ""
    @State private var lastSavedNote = ""
    @State private var isNoteVisible = false
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var hasLoadedGroupDetail = false

    @State private var previewImages: [WordGroupPreviewImage] = []
    @State private var currentImageIndex = 0
    @State private var showPhotoPickerSheet = false
    @State private var showPhotoPermissionAlert = false
    @State private var showArchiveConfirmation = false
    @State private var photoPermissionAlertMessage = SharedPhotoLibraryPermissionPolicy.deniedOrRestrictedMessage

    @FocusState private var isNoteEditorFocused: Bool

    private struct WordGroupPreviewImage: Identifiable {
        let id: Int64
        let assetIdentifier: String?
        let image: UIImage
    }

    private var hasImages: Bool {
        !previewImages.isEmpty
    }

    private var normalizedNote: String {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowNoteSection: Bool {
        isNoteVisible || !normalizedNote.isEmpty
    }

    private var shouldShowStandaloneEmptyState: Bool {
        words.isEmpty && !hasImages && !shouldShowNoteSection
    }

    private var normalizedCurrentImageIndex: Int {
        guard !previewImages.isEmpty else { return 0 }
        return min(max(currentImageIndex, 0), previewImages.count - 1)
    }

    private var currentPreviewImage: WordGroupPreviewImage? {
        guard !previewImages.isEmpty else { return nil }
        return previewImages[normalizedCurrentImageIndex]
    }

    private var selectedAssetIdentifiers: [String] {
        previewImages.compactMap(\.assetIdentifier)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中...")
            } else if shouldShowStandaloneEmptyState {
                ContentUnavailableView(
                    "组内暂无单词",
                    systemImage: "tray",
                    description: Text("先从单词列表左滑，把单词加入这个组。")
                )
            } else {
                List {
                    if hasImages {
                        imagePreviewSection
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                    }

                    if shouldShowNoteSection {
                        noteSection
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                            .listRowSeparator(.hidden)
                    }

                    if words.isEmpty {
                        Text("")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(words, id: \.self) { word in
                            NavigationLink {
                                DictionaryEntryView(service: dictionaryService, word: word)
                            }label: {
                                wordRow(word)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await removeWordFromGroup(word) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .padding(.top)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(groupName)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            if allowsArchiving {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("归档", systemImage: "archivebox") {
                        showArchiveConfirmation = true
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加图片", systemImage: "photo.on.rectangle") {
                        requestPhotoLibraryAccessAndPresentPicker()
                    }
                    Button("添加手记", systemImage: "square.and.pencil") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isNoteVisible = true
                        }
                        DispatchQueue.main.async {
                            isNoteEditorFocused = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("归档组", isPresented: $showArchiveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("归档", role: .destructive) {
                archiveGroup()
            }
        } message: {
            Text("归档后会从“集”的列表中移除，可在设置里的“归档”中查看。")
        }
        .alert("需要相册访问权限", isPresented: $showPhotoPermissionAlert) {
            Button("取消", role: .cancel) {}
            Button("去设置") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(settingsURL)
            }
        } message: {
            Text(photoPermissionAlertMessage)
        }
        .sheet(isPresented: $showPhotoPickerSheet) {
            WordGroupPhotoPickerSheet(
                selectionLimit: 9,
                preselectedAssetIdentifiers: selectedAssetIdentifiers
            ) { photos in
                showPhotoPickerSheet = false
                Task {
                    await appendPickedImages(photos)
                }
            }
        }
        .onChange(of: noteText) { _, _ in
            scheduleNoteSave()
        }
        .onDisappear {
            noteSaveTask?.cancel()
            guard hasLoadedGroupDetail else { return }
            let snapshot = noteText
            if snapshot != lastSavedNote {
                Task {
                    await UserDataService.shared.updateWordGroupNote(groupID: groupID, note: snapshot)
                }
            }
        }
        .task {
            guard !hasInitialLoadCompleted else { return }
            photoPermissionStore.refresh()
            await loadContent(showBlockingLoader: true)
            hasInitialLoadCompleted = true
        }
    }

    private var imagePreviewSection: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                let depth = min(previewImages.count, 9)
                ForEach(0..<depth, id: \.self) { level in
                    let index = (normalizedCurrentImageIndex + level) % previewImages.count
                    let image = previewImages[index]
                    let scale = 1.0 - CGFloat(level) * 0.05
                    let xOffset = CGFloat(level) * 12
                    let yOffset = CGFloat(level) * 8
                    let opacity = 1.0 - Double(level) * 0.2

                    Image(uiImage: image.image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .scaleEffect(scale)
                        .offset(x: xOffset, y: yOffset)
                        .opacity(opacity)
                        .zIndex(Double(depth - level))
                }
            }
            .frame(height: 240)
            .contentShape(Rectangle())
            .onTapGesture {
                cyclePreviewImage()
            }
            .contextMenu {
                Button("删除", systemImage: "trash", role: .destructive) {
                    deleteCurrentPreviewImage()
                }
            }


            if !previewImages.isEmpty {
                Text("\(normalizedCurrentImageIndex + 1)/\(previewImages.count)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(12)
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手记")
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if noteText.isEmpty {
                    Text("记下你的想法吧")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 14)
                }

                TextEditor(text: $noteText)
                    .focused($isNoteEditorFocused)
                    .frame(minHeight: 130)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .scrollDisabled(true)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func loadContent(showBlockingLoader: Bool) async {
        if showBlockingLoader {
            isLoading = true
        }
        hasLoadedGroupDetail = false
        defer {
            if showBlockingLoader {
                isLoading = false
            }
            hasLoadedGroupDetail = true
        }

        async let loadedWords = UserDataService.shared.fetchWords(inGroupID: groupID)
        async let loadedDetail = UserDataService.shared.fetchWordGroupDetail(groupID: groupID)
        let wordsResult = await loadedWords
        let detailResult = await loadedDetail
        let previews = await fetchWordPreviews(for: wordsResult)

        words = wordsResult
        wordPreviews = previews
        if let detailResult {
            noteText = detailResult.note
            lastSavedNote = detailResult.note
            if !detailResult.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isNoteVisible = true
            }
        }

        await reloadPreviewImages()
    }

    private func reloadPreviewImages() async {
        let imageRefs = await UserDataService.shared.fetchWordGroupImageRefs(groupID: groupID)
        var loadedImages: [WordGroupPreviewImage] = []
        loadedImages.reserveCapacity(imageRefs.count)

        for ref in imageRefs {
            guard let imageData = await UserDataService.shared.loadWordGroupImageData(groupID: ref.groupID, fileName: ref.fileName) else {
                continue
            }
            guard let image = UIImage(data: imageData) else {
                continue
            }
            loadedImages.append(
                WordGroupPreviewImage(
                    id: ref.id,
                    assetIdentifier: ref.assetIdentifier,
                    image: image
                )
            )
        }

        previewImages = loadedImages
        normalizeCurrentImageIndexIfNeeded()
    }

    private func cyclePreviewImage() {
        guard previewImages.count > 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            currentImageIndex = (normalizedCurrentImageIndex + 1) % previewImages.count
        }
    }

    private func deleteCurrentPreviewImage() {
        guard let currentPreviewImage else { return }
        let deleteIndex = normalizedCurrentImageIndex
        let deleteID = currentPreviewImage.id

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            previewImages.remove(at: deleteIndex)
            normalizeCurrentImageIndexIfNeeded()
        }

        Task {
            await UserDataService.shared.deleteWordGroupImage(imageID: deleteID)
        }
    }

    private func normalizeCurrentImageIndexIfNeeded() {
        if previewImages.isEmpty {
            currentImageIndex = 0
        } else {
            currentImageIndex = min(max(currentImageIndex, 0), previewImages.count - 1)
        }
    }

    private func appendPickedImages(_ photos: [WordGroupPickedPhoto]) async {
        guard !photos.isEmpty else { return }

        let existingAssetIDs = Set(previewImages.compactMap(\.assetIdentifier))
        let uniquePhotos = photos.filter { photo in
            guard let assetIdentifier = photo.assetIdentifier else { return true }
            return !existingAssetIDs.contains(assetIdentifier)
        }

        let inputs = uniquePhotos.compactMap { photo -> UserDataService.WordGroupImageInput? in
            guard let imageData = photo.image.jpegData(compressionQuality: 0.82) else { return nil }
            return UserDataService.WordGroupImageInput(
                imageData: imageData,
                assetIdentifier: photo.assetIdentifier
            )
        }

        guard !inputs.isEmpty else { return }

        await UserDataService.shared.appendWordGroupImages(groupID: groupID, images: inputs)
        await reloadPreviewImages()
    }

    private func requestPhotoLibraryAccessAndPresentPicker() {
        Task {
            let status = await photoPermissionStore.requestReadWriteStatusIfNeeded()
            let decision = SharedPhotoLibraryPermissionPolicy.decision(for: status)
            await MainActor.run {
                if decision.canPresentPicker {
                    showPhotoPickerSheet = true
                } else if let alertMessage = decision.alertMessage {
                    photoPermissionAlertMessage = alertMessage
                    showPhotoPermissionAlert = true
                }
            }
        }
    }

    private func archiveGroup() {
        Task {
            let didArchive = await UserDataService.shared.archiveWordGroup(groupID: groupID)
            guard didArchive else { return }
            await MainActor.run {
                onArchived?()
                dismiss()
            }
        }
    }

    private func scheduleNoteSave() {
        guard hasLoadedGroupDetail else { return }

        noteSaveTask?.cancel()
        let snapshot = noteText

        guard snapshot != lastSavedNote else { return }

        noteSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await UserDataService.shared.updateWordGroupNote(groupID: groupID, note: snapshot)
            await MainActor.run {
                lastSavedNote = snapshot
            }
        }
    }

    private func removeWordFromGroup(_ word: String) async {
        await UserDataService.shared.removeWord(word, fromGroupID: groupID)
        let latestWords = await UserDataService.shared.fetchWords(inGroupID: groupID)
        words = latestWords
        wordPreviews = await fetchWordPreviews(for: latestWords)
    }

    private func wordRow(_ word: String) -> some View {
        HStack(spacing: 10) {
            Text(word)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if let preview = wordPreviews[word]?.compactPreviewText(posStyle: .abbreviation), !preview.isEmpty {
                Text(preview)
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
            return try await dictionaryService.fetchWordListPreviews(words: words)
        } catch {
            return [:]
        }
    }
}
