import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FolderPickerSheet: View {
    @Binding var isPresented: Bool
    let onImport: (URL) -> Void

    @State private var selectedFolderURL: URL?
    @State private var showFolderPicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("导入词典目录")
                    .font(.headline)

                Text("请选择包含 .mdx、可选 .mdd 以及相关资源文件的文件夹。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let selectedFolderURL {
                    labeledPathRow(title: "目录", path: selectedFolderURL.lastPathComponent)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("选择词典目录") {
                        errorMessage = nil
                        showFolderPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button("开始导入") {
                    guard let selectedFolderURL else { return }
                    onImport(selectedFolderURL)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolderURL == nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding()
            .navigationTitle("添加词典")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                DictionaryFolderPicker(asCopy: false) { pickedURL in
                    handlePickedFolder(pickedURL)
                    showFolderPicker = false
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func labeledPathRow(title: String, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(title):")
                .font(.subheadline.bold())
            Text(path)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func handlePickedFolder(_ pickedURL: URL?) {
        guard let folderURL = pickedURL else { return }

        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            errorMessage = "请选择一个可读取的目录。"
            return
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            errorMessage = "无法访问所选目录，请确认文件权限后重试"
            return
        }

        selectedFolderURL = folderURL
        errorMessage = nil
    }
}

private struct DictionaryFolderPicker: UIViewControllerRepresentable {
    let asCopy: Bool
    let onPicked: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: asCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPicked: (URL?) -> Void

        init(onPicked: @escaping (URL?) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DispatchQueue.main.async {
                self.onPicked(urls.first)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.onPicked(nil)
            }
        }
    }
}
