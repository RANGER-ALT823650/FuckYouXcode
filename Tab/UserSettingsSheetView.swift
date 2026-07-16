//
//  UserSettingsSheetView.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import SwiftUI
import PhotosUI
import MessageUI

struct UserAvatarCircleView: View {
    let image: UIImage?
    var size: CGFloat

    init(image: UIImage?, size: CGFloat = 28) {
        self.image = image
        self.size = size
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private enum SevenDayBuildCountdown {
    private struct BuildIdentity {
        let signature: String
        let date: Date
    }

    private static let buildSignatureKey = "settingsCountdown.buildSignature"
    private static let deadlineKey = "settingsCountdown.deadline"
    private static let duration: TimeInterval = 7 * 24 * 60 * 60

    static func deadline(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) -> Date {
        let buildIdentity = buildIdentity(for: bundle, fallbackDate: now)
        let storedSignature = defaults.string(forKey: buildSignatureKey)
        let storedDeadline = defaults.object(forKey: deadlineKey) as? Date

        guard storedSignature == buildIdentity.signature, let storedDeadline else {
            let newDeadline = buildIdentity.date.addingTimeInterval(duration)
            defaults.set(buildIdentity.signature, forKey: buildSignatureKey)
            defaults.set(newDeadline, forKey: deadlineKey)
            return newDeadline
        }

        return storedDeadline
    }

    static func text(until deadline: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(deadline.timeIntervalSince(now)))
        guard totalSeconds > 0 else { return "已结束" }

        let days = totalSeconds / 86_400
        let hours = totalSeconds % 86_400 / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        return String(format: "%d天 %02d:%02d:%02d", days, hours, minutes, seconds)
    }

    private static func buildIdentity(for bundle: Bundle, fallbackDate: Date) -> BuildIdentity {
        let bundleAttributes = try? FileManager.default.attributesOfItem(atPath: bundle.bundleURL.path)
        let executableAttributes = bundle.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)
        }
        let bundleModificationDate = bundleAttributes?[.modificationDate] as? Date
        let executableModificationDate = executableAttributes?[.modificationDate] as? Date
        let executableSize = (executableAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let buildDate = [bundleModificationDate, executableModificationDate]
            .compactMap { $0 }
            .max() ?? fallbackDate

        // The installed bundle path changes when Xcode deploys a new build to a device.
        let signature = "\(bundle.bundleURL.path)-\(bundleModificationDate?.timeIntervalSince1970 ?? 0)-\(executableModificationDate?.timeIntervalSince1970 ?? 0)-\(executableSize)"
        return BuildIdentity(signature: signature, date: buildDate)
    }
}

@MainActor
struct UserSettingsSheetView: View {
    private struct AvatarCropSession: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    @ObservedObject var profileStore: UserProfileSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var photoPermissionStore = SharedPhotoLibraryPermissionStore.shared

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var avatarCropSession: AvatarCropSession?
    @State private var showAvatarPhotoPicker = false
    @State private var showPhotoPermissionAlert = false
    @State private var showMailComposer = false
    @State private var showMailUnavailableAlert = false
    @State private var photoPermissionAlertMessage = SharedPhotoLibraryPermissionPolicy.deniedOrRestrictedMessage
    @State private var nicknameDraft: String = ""
    @AppStorage(AppAppearanceController.darkModeStorageKey) private var isDarkModeEnabled = false
    @FocusState private var isNicknameFieldFocused: Bool
    private let countdownDeadline = SevenDayBuildCountdown.deadline()
    private let policyAndTermsURLString = "https://ranger-alt823650.github.io/privacy-policy-terms/"
    private let policyAndTermsFallbackURL = URL(string: "https://example.com")!
    private let xiaohongshuURLString = "https://www.xiaohongshu.com/user/profile/6788e058000000000803f0b9"
    private let xiaohongshuFallbackURL = URL(string: "https://www.xiaohongshu.com")!
    private let appStoreReviewAppID = "0000000000"
    private let appStoreReviewFallbackURL = URL(string: "https://apps.apple.com")!
    private let developerRecipientEmail = "yifanm852@gmail.com"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack {
                            Label("七天倒计时", systemImage: "timer")
                            Spacer()
                            Text(SevenDayBuildCountdown.text(until: countdownDeadline, now: context.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Button {
                        requestPhotoLibraryAccessAndPresentAvatarPicker()
                    } label: {
                        HStack {
                            Text("头像")
                            Spacer()
                            UserAvatarCircleView(image: profileStore.avatarImage, size: 34)
                        }
                    }
                    .buttonStyle(.plain)
                    .photosPicker(isPresented: $showAvatarPhotoPicker, selection: $avatarPickerItem, matching: .images)
                    .alert("需要相册访问权限", isPresented: $showPhotoPermissionAlert) {
                        Button("取消", role: .cancel) {}
                        Button("去设置") {
                            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(settingsURL)
                        }
                    } message: {
                        Text(photoPermissionAlertMessage)
                    }

                    HStack {
                        Text("昵称")
                        Spacer()
                        TextField("输入昵称", text: $nicknameDraft)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .focused($isNicknameFieldFocused)
                            .onSubmit {
                                profileStore.updateNickname(nicknameDraft)
                                nicknameDraft = profileStore.nickname
                            }
                    }

                    Toggle("深色模式", isOn: darkModeToggleBinding)

                    NavigationLink {
                        ArchivedWordGroupsView()
                    } label: {
                        Label("归档", systemImage: "archivebox")
                    }
                }

                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 设置", systemImage: "sparkles")
                    }

                    NavigationLink {
                        AIChatHistoryView()
                    } label: {
                        Label("AI 聊天记录", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section {
                    NavigationLink("🔍 使用帮助") {
                        InstructionView()
                    }

                    Link(destination: policyAndTermsURL) {
                        Text("✍️ 隐私政策&服务条款")
                            .tint(.primary)
                    }
                }

                Section {
                    Button("📨 联系开发者") {
                        presentMailComposer()
                    }
                    .buttonStyle(.plain)
                    
                    Link(destination: xiaohongshuURL) {
                        Text("📎 小红书")
                            .tint(.primary)
                    }
                    Link(destination: appStoreReviewURL) {
                        Text("👥 评价")
                            .tint(.primary)
                    }
                }

                // TEMP: iCloud disabled
                // Section {
                //     UserSyncSettingsSectionContent()
                // }
            }
            //.navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        profileStore.updateNickname(nicknameDraft)
                        nicknameDraft = profileStore.nickname
                        dismiss()
                    }
                }
            }
            .onAppear {
                photoPermissionStore.refresh()
                nicknameDraft = profileStore.nickname
            }
            .onDisappear {
                profileStore.updateNickname(nicknameDraft)
            }
            .onChange(of: avatarPickerItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    guard let data = try? await newValue.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        await MainActor.run {
                            clearAvatarPickerFlow()
                        }
                        return
                    }
                    await MainActor.run {
                        avatarCropSession = AvatarCropSession(image: image)
                    }
                }
            }
            .onChange(of: nicknameDraft) { _, newValue in
                if newValue.count > 24 {
                    nicknameDraft = String(newValue.prefix(24))
                }
            }
            .onChange(of: isNicknameFieldFocused) { _, focused in
                guard !focused else { return }
                profileStore.updateNickname(nicknameDraft)
                nicknameDraft = profileStore.nickname
            }
            .sheet(isPresented: $showMailComposer) {
                MailComposeView(recipients: developerRecipients)
            }
            .alert("无法发送邮件", isPresented: $showMailUnavailableAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("请先在系统“邮件”App中登录邮箱账号后再试。")
            }
        }
        .fullScreenCover(item: $avatarCropSession, onDismiss: {
            avatarPickerItem = nil
        }) { session in
            AvatarPhotoCropperView(
                sourceImage: session.image,
                onCancel: {
                    clearAvatarPickerFlow()
                },
                onChoose: { croppedImage in
                    _ = profileStore.saveAvatar(image: croppedImage)
                    clearAvatarPickerFlow()
                }
            )
        }
    }

    private func clearAvatarPickerFlow() {
        avatarCropSession = nil
        avatarPickerItem = nil
    }

    private var darkModeToggleBinding: Binding<Bool> {
        Binding(
            get: { isDarkModeEnabled },
            set: { newValue in
                guard newValue != isDarkModeEnabled else { return }
                isDarkModeEnabled = newValue
                AppAppearanceController.applyDarkMode(newValue, animated: true, duration: 0.45)
            }
        )
    }

    private func requestPhotoLibraryAccessAndPresentAvatarPicker() {
        Task {
            let status = await photoPermissionStore.requestReadWriteStatusIfNeeded()
            let decision = SharedPhotoLibraryPermissionPolicy.decision(for: status)
            await MainActor.run {
                if decision.canPresentPicker {
                    showAvatarPhotoPicker = true
                } else if let alertMessage = decision.alertMessage {
                    photoPermissionAlertMessage = alertMessage
                    showPhotoPermissionAlert = true
                }
            }
        }
    }

    private func presentMailComposer() {
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
        } else {
            showMailUnavailableAlert = true
        }
    }

    private var developerRecipients: [String] {
        let trimmed = developerRecipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private var policyAndTermsURL: URL {
        URL(string: policyAndTermsURLString) ?? policyAndTermsFallbackURL
    }

    private var xiaohongshuURL: URL {
        URL(string: xiaohongshuURLString) ?? xiaohongshuFallbackURL
    }

    private var appStoreReviewURL: URL {
        // TODO: Replace placeholder App Store ID with the real app ID.
        URL(string: "https://apps.apple.com/app/id\(appStoreReviewAppID)?action=write-review") ?? appStoreReviewFallbackURL
    }
}

private struct ArchivedWordGroupsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var archivedGroups: [UserDataService.WordGroupSummary] = []
    @State private var isLoading = false
    @State private var hasInitialLoadCompleted = false

    private var dictionaryService: DictionaryService? {
        appState.service(for: appState.selectedDictionaryID)
            ?? appState.service(for: DictionaryOption.defaultID)
            ?? appState.dictionaryService
    }

    var body: some View {
        Group {
            if isLoading && !hasInitialLoadCompleted {
                ProgressView("加载中...")
            } else if archivedGroups.isEmpty {
                ContentUnavailableView(
                    "暂无归档",
                    systemImage: "archivebox",
                    description: Text("归档后的组和父组会显示在这里。")
                )
            } else {
                List(archivedGroups) { group in
                    NavigationLink {
                        archivedDestination(for: group)
                    } label: {
                        ArchivedWordGroupRow(group: group)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            restoreArchivedGroup(group)
                        } label: {
                            Label("移出归档", systemImage: "tray.and.arrow.up")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button("移出归档", systemImage: "tray.and.arrow.up") {
                            restoreArchivedGroup(group)
                        }
                    }
                }
                .refreshable {
                    await reloadArchivedGroups(showBlockingLoader: false)
                }
            }
        }
        .navigationTitle("归档")
        .task {
            guard !hasInitialLoadCompleted else { return }
            await reloadArchivedGroups(showBlockingLoader: true)
            hasInitialLoadCompleted = true
        }
    }

    @ViewBuilder
    private func archivedDestination(for group: UserDataService.WordGroupSummary) -> some View {
        if let dictionaryService {
            switch group.kind {
            case .parent:
                WordGroupChildrenListView(
                    dictionaryService: dictionaryService,
                    parentGroup: group,
                    includeArchivedChildren: true,
                    allowsArchiving: false
                )
            case .group:
                WordCollectionDetailView(
                    dictionaryService: dictionaryService,
                    groupID: group.id,
                    groupName: group.name,
                    allowsArchiving: false
                )
            }
        } else {
            ContentUnavailableView(
                "词典未加载",
                systemImage: "exclamationmark.triangle",
                description: Text("请稍后再试。")
            )
        }
    }

    private func reloadArchivedGroups(showBlockingLoader: Bool) async {
        if showBlockingLoader {
            isLoading = true
        }
        defer {
            if showBlockingLoader {
                isLoading = false
            }
        }

        archivedGroups = await UserDataService.shared.fetchArchivedWordGroups()
    }

    private func restoreArchivedGroup(_ group: UserDataService.WordGroupSummary) {
        Task {
            let didRestore = await UserDataService.shared.restoreWordGroupFromArchive(groupID: group.id)
            guard didRestore else { return }
            await reloadArchivedGroups(showBlockingLoader: false)
        }
    }
}

private struct ArchivedWordGroupRow: View {
    let group: UserDataService.WordGroupSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.kind == .parent ? "folder.fill" : "folder")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(group.kind == .parent ? "父组" : "组")
                    if group.kind == .group, let parentName = group.parentName, !parentName.isEmpty {
                        Text(parentName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let archivedAt = group.archivedAt {
                Text(formattedArchiveDate(archivedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private func formattedArchiveDate(_ timestamp: Int64) -> String {
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

private struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        if !recipients.isEmpty {
            controller.setToRecipients(recipients)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
}
