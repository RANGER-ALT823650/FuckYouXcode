//
//  UserSyncSettingsView.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import SwiftUI

// TEMP: iCloud disabled for non-paid Apple Developer account.
// Keep implementation for future re-enable.
#if false

struct UserSyncSettingsSectionContent: View {
    @State private var status = UserCloudSyncStatus(
        isEnabled: false,
        isICloudAvailable: false,
        isSyncing: false,
        lastSyncAt: nil,
        lastErrorMessage: nil
    )
    @State private var syncEnabled = false
    @State private var isWorking = false
    @State private var showDisableConfirmation = false

    var body: some View {
        Toggle("iCloud 同步", isOn: Binding(
            get: { syncEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        isWorking = true
                        await UserCloudSyncService.shared.setSyncEnabled(true)
                        await refreshStatus()
                        isWorking = false
                    }
                } else {
                    showDisableConfirmation = true
                }
            }
        ))
        .disabled(isWorking || status.isSyncing)

        HStack {
            Text("同步状态")
            Spacer()
            Text(statusText)
                .foregroundStyle(.secondary)
        }

        if let lastSyncAt = status.lastSyncAt {
            HStack {
                Text("上次同步")
                Spacer()
                Text(Self.statusDateFormatter.string(from: lastSyncAt))
                    .foregroundStyle(.secondary)
            }
        }

        if let error = status.lastErrorMessage, !error.isEmpty {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }

        Button {
            Task {
                isWorking = true
                await UserCloudSyncService.shared.performManualSync()
                await refreshStatus()
                isWorking = false
            }
        } label: {
            HStack {
                Text("立即同步")
                if isWorking || status.isSyncing {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(!status.isEnabled || !status.isICloudAvailable || isWorking || status.isSyncing)
        .confirmationDialog("关闭 iCloud 同步", isPresented: $showDisableConfirmation) {
            Button("仅关闭同步", role: .none) {
                Task {
                    isWorking = true
                    await UserCloudSyncService.shared.disableSync(deleteCloudMirror: false)
                    await refreshStatus()
                    isWorking = false
                }
            }
            Button("关闭并删除云端副本", role: .destructive) {
                Task {
                    isWorking = true
                    await UserCloudSyncService.shared.disableSync(deleteCloudMirror: true)
                    await refreshStatus()
                    isWorking = false
                }
            }
            Button("取消", role: .cancel) {
                syncEnabled = status.isEnabled
            }
        } message: {
            Text("关闭后你可以选择保留云端副本，或同时删除云端数据。")
        }
        .task {
            await refreshStatus()
        }
    }

    private var statusText: String {
        if status.isSyncing {
            return "同步中..."
        }
        if !status.isICloudAvailable {
            return "iCloud 不可用"
        }
        return status.isEnabled ? "已开启" : "已关闭"
    }

    private func refreshStatus() async {
        let snapshot = await UserCloudSyncService.shared.statusSnapshot()
        status = snapshot
        syncEnabled = snapshot.isEnabled
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct UserSyncSettingsView: View {
    var body: some View {
        List {
            Section("iCloud 同步") {
                UserSyncSettingsSectionContent()
            }
        }
        .navigationTitle("同步设置")
    }
}

#endif
