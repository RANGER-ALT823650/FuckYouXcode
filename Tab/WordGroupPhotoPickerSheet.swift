//
//  WordGroupPhotoPickerSheet.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/19.
//

import SwiftUI
import PhotosUI
import UIKit
import Photos
import Combine

struct WordGroupPickedPhoto {
    let assetIdentifier: String?
    let image: UIImage
}

struct WordGroupPhotoPickerSheet: UIViewControllerRepresentable {
    let selectionLimit: Int
    let preselectedAssetIdentifiers: [String]
    let onComplete: ([WordGroupPickedPhoto]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = selectionLimit
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        configuration.preselectedAssetIdentifiers = preselectedAssetIdentifiers

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: WordGroupPhotoPickerSheet

        init(parent: WordGroupPhotoPickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                DispatchQueue.main.async {
                    self.parent.onComplete([])
                }
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            var indexedPhotos: [(Int, WordGroupPickedPhoto)] = []

            for (index, result) in results.enumerated() {
                guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }

                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }

                    guard let image = object as? UIImage else { return }
                    lock.lock()
                    indexedPhotos.append(
                        (index, WordGroupPickedPhoto(assetIdentifier: result.assetIdentifier, image: image))
                    )
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                let orderedPhotos = indexedPhotos
                    .sorted { $0.0 < $1.0 }
                    .map(\.1)
                self.parent.onComplete(orderedPhotos)
            }
        }
    }
}

@MainActor
final class SharedPhotoLibraryPermissionStore: ObservableObject {
    static let shared = SharedPhotoLibraryPermissionStore()

    @Published private(set) var status: PHAuthorizationStatus

    private var inFlightRequestTask: Task<PHAuthorizationStatus, Never>?

    private init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestReadWriteStatusIfNeeded() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard currentStatus == .notDetermined else {
            status = currentStatus
            return currentStatus
        }

        if let inFlightRequestTask {
            let resolvedStatus = await inFlightRequestTask.value
            status = resolvedStatus
            return resolvedStatus
        }

        let task = Task<PHAuthorizationStatus, Never> {
            await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        }

        inFlightRequestTask = task
        let resolvedStatus = await task.value
        inFlightRequestTask = nil
        status = resolvedStatus
        return resolvedStatus
    }
}

enum SharedPhotoLibraryPermissionPolicy {
    static let deniedOrRestrictedMessage = "请允许访问相册（所有照片），以便在选择器里同步已选中图片状态。"
    static let limitedMessage = "当前为“部分照片”权限，系统可能不会返回可预选的资源标识。请在设置里将照片权限改为“所有照片”，再使用此功能。"

    struct Decision {
        let canPresentPicker: Bool
        let alertMessage: String?
    }

    static func decision(for status: PHAuthorizationStatus) -> Decision {
        switch status {
        case .authorized:
            return Decision(canPresentPicker: true, alertMessage: nil)
        case .limited:
            return Decision(canPresentPicker: false, alertMessage: limitedMessage)
        default:
            return Decision(canPresentPicker: false, alertMessage: deniedOrRestrictedMessage)
        }
    }
}
