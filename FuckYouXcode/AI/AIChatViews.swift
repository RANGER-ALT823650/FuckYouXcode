import SwiftUI
import UIKit

struct AIChatSheetView: View {
    @EnvironmentObject private var settingsStore: AISettingsStore
    @EnvironmentObject private var historyStore: AIChatHistoryStore
    @Environment(\.dismiss) private var dismiss

    let contextWord: String

    @State private var sessionID: UUID?
    @State private var messageDraft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var showDeleteSessionConfirmation = false
    @FocusState private var isComposerFocused: Bool

    private var session: AIChatSession? {
        guard let sessionID else { return nil }
        return historyStore.session(id: sessionID)
    }

    private var trimmedDraft: String {
        messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AIChatTranscriptView(messages: session?.messages ?? [], isSending: isSending)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

                VStack(spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }

                    composer
                }
            }
            .navigationTitle(contextWord.isEmpty ? "AI" : contextWord)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        sendTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteSessionConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(session?.messages.isEmpty ?? true)
                }
            }
            .onAppear {
                sessionID = historyStore.existingSessionID(contextWord: contextWord)
            }
            .onChange(of: historyStore.sessions) { _, _ in
                synchronizeCurrentSession()
            }
            .onDisappear {
                sendTask?.cancel()
            }
            .alert("删除当前 AI 对话？", isPresented: $showDeleteSessionConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteCurrentSession()
                }
            } message: {
                Text("这会删除当前词条的 AI 聊天记录，操作无法撤销。")
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !settingsStore.isConfigured {
                Text("请先在用户设置里配置 AI。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("问问 AI…", text: $messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        sendMessage()
                    }

                Button {
                    sendMessage()
                } label: {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settingsStore.isConfigured || trimmedDraft.isEmpty || isSending)
            }
        }
        .padding()
    }

    private func sendMessage() {
        guard settingsStore.isConfigured,
              !trimmedDraft.isEmpty,
              !isSending else {
            return
        }

        let activeSessionID: UUID
        if let sessionID, historyStore.session(id: sessionID) != nil {
            activeSessionID = sessionID
        } else {
            activeSessionID = historyStore.ensureSessionID(contextWord: contextWord)
        }
        sessionID = activeSessionID
        let text = trimmedDraft
        messageDraft = ""
        errorMessage = nil

        let userMessage = AIChatMessage(role: .user, content: text)
        historyStore.appendMessage(userMessage, to: activeSessionID)

        guard let session = historyStore.session(id: activeSessionID) else { return }
        let requestMessages = makeRequestMessages(from: session.messages)
        isSending = true

        sendTask?.cancel()
        sendTask = Task {
            do {
                var assistantMessageID: UUID?
                for try await contentDelta in OpenAIChatClient().stream(
                    messages: requestMessages,
                    configuration: settingsStore.configuration
                ) {
                    if Task.isCancelled { return }

                    if let existingID = assistantMessageID {
                        historyStore.appendContent(contentDelta, to: existingID, in: activeSessionID)
                    } else {
                        let assistantMessage = AIChatMessage(role: .assistant, content: contentDelta)
                        assistantMessageID = assistantMessage.id
                        historyStore.appendMessage(assistantMessage, to: activeSessionID)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isSending = false
            }
        }
    }

    private func makeRequestMessages(from messages: [AIChatMessage]) -> [AIChatMessage] {
        let normalizedWord = contextWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if normalizedWord.isEmpty {
            prompt = settingsStore.systemPrompt
        } else {
            prompt = "\(settingsStore.systemPrompt)\n当前词条：\(normalizedWord)"
        }

        return [AIChatMessage(role: .system, content: prompt)] + messages
    }

    private func deleteCurrentSession() {
        guard let sessionID else { return }
        sendTask?.cancel()
        historyStore.deleteSession(id: sessionID)
        self.sessionID = nil
        isSending = false
        errorMessage = nil
    }

    private func synchronizeCurrentSession() {
        guard let sessionID else { return }
        guard historyStore.session(id: sessionID) == nil else { return }
        sendTask?.cancel()
        self.sessionID = nil
        isSending = false
        errorMessage = nil
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct AISettingsView: View {
    @EnvironmentObject private var settingsStore: AISettingsStore

    var body: some View {
        Form {
            Section("模型提供方") {
                TextField("Base URL", text: $settingsStore.baseURLString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                TextField("模型", text: $settingsStore.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API Key", text: $settingsStore.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("系统提示词") {
                TextEditor(text: $settingsStore.systemPrompt)
                    .frame(minHeight: 140)
            }
        }
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AIChatHistoryView: View {
    @EnvironmentObject private var historyStore: AIChatHistoryStore
    @State private var showClearAllConfirmation = false
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        Group {
            if historyStore.sortedSessions.isEmpty {
                ContentUnavailableView("暂无 AI 聊天记录", systemImage: "bubble.left.and.bubble.right")
            } else {
                List {
                    ForEach(historyStore.sortedSessions) { session in
                        NavigationLink {
                            AIChatSessionDetailView(sessionID: session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title)
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    Text("\(session.messages.count) 条消息")
                                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                    }
                }
            }
        }
        .navigationTitle("AI 聊天记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(historyStore.sortedSessions.isEmpty)
            }
        }
        .alert("删除全部 AI 聊天记录？", isPresented: $showClearAllConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                historyStore.clearAll()
            }
        } message: {
            Text("这会删除所有 AI 聊天记录，操作无法撤销。")
        }
        .alert(
            "删除这条 AI 聊天记录？",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteOffsets = nil
                    }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingDeleteOffsets = nil
            }
            Button("删除", role: .destructive) {
                if let pendingDeleteOffsets {
                    historyStore.deleteSessions(at: pendingDeleteOffsets)
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("这会删除所选 AI 聊天记录，操作无法撤销。")
        }
    }
}

struct AIChatSessionDetailView: View {
    @EnvironmentObject private var historyStore: AIChatHistoryStore
    let sessionID: UUID

    var body: some View {
        Group {
            if let session = historyStore.session(id: sessionID) {
                AIChatTranscriptView(messages: session.messages, isSending: false)
                    .navigationTitle(session.title)
            } else {
                ContentUnavailableView("记录不存在", systemImage: "bubble.left")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AIChatTranscriptView: View {
    let messages: [AIChatMessage]
    var isSending: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !isSending {
                        ContentUnavailableView("输入问题开始对话", systemImage: "sparkles")
                            .padding(.top, 48)
                    }

                    ForEach(messages) { message in
                        AIChatMessageBubble(message: message)
                    }

                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("思考中…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 14)
                .padding(.bottom, 112)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: isSending) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemBackground).opacity(0),
                        Color(uiColor: .systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 42)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct AIChatMessageBubble: View {
    let message: AIChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 40)
            }

            messageContent
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var messageContent: some View {
        if isUser {
            MarkdownMessageText(content: message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.vertical, 6)
        } else {
            SelectableMarkdownText(content: message.content)
                .padding(.vertical, 6)
        }
    }
}

private struct SelectableMarkdownText: UIViewRepresentable {
    let content: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = Self.attributedText(from: content)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(fittingSize)
        return CGSize(width: width, height: size.height)
    }

    private static func attributedText(from content: String) -> NSAttributedString {
        let source = content.isEmpty ? " " : content
        let attributed: NSAttributedString

        if let markdown = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            attributed = NSAttributedString(markdown)
        } else {
            attributed = NSAttributedString(string: source)
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 9
        paragraphStyle.lineSpacing = 2
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard value == nil else { return }
            mutable.addAttribute(
                .font,
                value: UIFont.preferredFont(forTextStyle: .body),
                range: range
            )
        }

        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard value == nil else { return }
            mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        }

        return mutable
    }
}

private struct MarkdownMessageText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(markdownBlocks, id: \.offset) { block in
                markdownText(block.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var markdownBlocks: [(offset: Int, text: String)] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return [(0, "")]
        }

        var blocks: [(offset: Int, text: String)] = []
        var currentLines: [String] = []
        var currentIsList = false

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                appendBlock(&blocks, lines: &currentLines)
                currentIsList = false
                continue
            }

            let lineIsList = Self.isListLine(line)
            if !currentLines.isEmpty, currentIsList != lineIsList {
                appendBlock(&blocks, lines: &currentLines)
            }

            currentLines.append(rawLine)
            currentIsList = lineIsList
        }

        appendBlock(&blocks, lines: &currentLines)
        return blocks
    }

    private func appendBlock(
        _ blocks: inout [(offset: Int, text: String)],
        lines: inout [String]
    ) {
        let text = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append((blocks.count, text))
        }
        lines.removeAll()
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(value)
    }

    private static func isListLine(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }

        let pattern = #"^\d+[\.)]\s+"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }
}
