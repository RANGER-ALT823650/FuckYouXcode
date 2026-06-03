//
//  AvatarPhotoCropperView.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import SwiftUI
import UIKit

struct AvatarPhotoCropperView: View {
    private struct RenderLayout {
        let cropRect: CGRect
        let imageSize: CGSize
        let imageCenter: CGPoint
    }

    private let image: UIImage
    let onCancel: () -> Void
    let onChoose: (UIImage) -> Void

    @State private var committedScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @State private var transientScale: CGFloat = 1
    @State private var transientOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    init(sourceImage: UIImage, onCancel: @escaping () -> Void, onChoose: @escaping (UIImage) -> Void) {
        self.image = sourceImage.normalizedForAvatarCrop()
        self.onCancel = onCancel
        self.onChoose = onChoose
    }

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom
            let cropDiameter = cropDiameter(in: containerSize, safeTop: safeTop, safeBottom: safeBottom)

            let effectiveScale = clampedScale(committedScale * transientScale)
            let proposedOffset = CGSize(
                width: committedOffset.width + transientOffset.width,
                height: committedOffset.height + transientOffset.height
            )
            let effectiveOffset = clampedOffset(
                proposedOffset,
                cropDiameter: cropDiameter,
                scale: effectiveScale
            )
            let layout = renderLayout(
                containerSize: containerSize,
                cropDiameter: cropDiameter,
                scale: effectiveScale,
                offset: effectiveOffset
            )

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: layout.imageSize.width, height: layout.imageSize.height)
                    .position(layout.imageCenter)
                    .gesture(dragGesture(cropDiameter: cropDiameter))
                    .simultaneousGesture(magnificationGesture(cropDiameter: cropDiameter))

                AvatarCropMaskOverlay(cropRect: layout.cropRect)

                VStack {
                    Spacer()
                    HStack {
                        Button("Cancel", role: .cancel) {
                            onCancel()
                        }

                        Spacer()

                        Button("Choose") {
                            guard let croppedImage = cropAvatar(
                                containerSize: containerSize,
                                cropDiameter: cropDiameter,
                                scale: effectiveScale,
                                offset: effectiveOffset
                            ) else {
                                onCancel()
                                return
                            }
                            onChoose(croppedImage)
                        }
                    }
                    .font(.system(size: 30, weight: .regular, design: .default))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, max(18, safeBottom + 8))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func cropDiameter(in size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        let horizontal = size.width - 24
        let vertical = size.height - safeTop - safeBottom - 180
        let candidate = min(horizontal, vertical)
        return max(120, candidate)
    }

    private func baseScale(for cropDiameter: CGFloat) -> CGFloat {
        max(cropDiameter / image.size.width, cropDiameter / image.size.height)
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    private func clampedOffset(_ offset: CGSize, cropDiameter: CGFloat, scale: CGFloat) -> CGSize {
        let totalScale = baseScale(for: cropDiameter) * scale
        let displayedSize = CGSize(
            width: image.size.width * totalScale,
            height: image.size.height * totalScale
        )
        let xLimit = max((displayedSize.width - cropDiameter) / 2, 0)
        let yLimit = max((displayedSize.height - cropDiameter) / 2, 0)

        return CGSize(
            width: min(max(offset.width, -xLimit), xLimit),
            height: min(max(offset.height, -yLimit), yLimit)
        )
    }

    private func renderLayout(
        containerSize: CGSize,
        cropDiameter: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> RenderLayout {
        let totalScale = baseScale(for: cropDiameter) * scale
        let imageSize = CGSize(
            width: image.size.width * totalScale,
            height: image.size.height * totalScale
        )
        let center = CGPoint(
            x: containerSize.width / 2 + offset.width,
            y: containerSize.height / 2 + offset.height
        )
        let cropRect = CGRect(
            x: (containerSize.width - cropDiameter) / 2,
            y: (containerSize.height - cropDiameter) / 2,
            width: cropDiameter,
            height: cropDiameter
        )

        return RenderLayout(cropRect: cropRect, imageSize: imageSize, imageCenter: center)
    }

    private func dragGesture(cropDiameter: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                transientOffset = value.translation
            }
            .onEnded { value in
                let scale = clampedScale(committedScale * transientScale)
                let proposedOffset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
                committedOffset = clampedOffset(
                    proposedOffset,
                    cropDiameter: cropDiameter,
                    scale: scale
                )
                transientOffset = .zero
            }
    }

    private func magnificationGesture(cropDiameter: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                transientScale = value
            }
            .onEnded { value in
                let newScale = clampedScale(committedScale * value)
                committedScale = newScale
                committedOffset = clampedOffset(
                    committedOffset,
                    cropDiameter: cropDiameter,
                    scale: newScale
                )
                transientScale = 1
            }
    }

    private func cropAvatar(
        containerSize: CGSize,
        cropDiameter: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> UIImage? {
        let totalScale = baseScale(for: cropDiameter) * scale
        guard totalScale > 0 else { return nil }

        let renderedSize = CGSize(
            width: image.size.width * totalScale,
            height: image.size.height * totalScale
        )
        let imageRect = CGRect(
            x: (containerSize.width - renderedSize.width) / 2 + offset.width,
            y: (containerSize.height - renderedSize.height) / 2 + offset.height,
            width: renderedSize.width,
            height: renderedSize.height
        )
        let cropRect = CGRect(
            x: (containerSize.width - cropDiameter) / 2,
            y: (containerSize.height - cropDiameter) / 2,
            width: cropDiameter,
            height: cropDiameter
        )
        let imageSpaceRect = CGRect(
            x: (cropRect.minX - imageRect.minX) / totalScale,
            y: (cropRect.minY - imageRect.minY) / totalScale,
            width: cropRect.width / totalScale,
            height: cropRect.height / totalScale
        )
        let boundedRect = imageSpaceRect
            .intersection(CGRect(origin: .zero, size: image.size))
            .standardized
        guard boundedRect.width > 1, boundedRect.height > 1 else { return nil }

        return image.cropped(to: boundedRect)
    }
}

private struct AvatarCropMaskOverlay: View {
    let cropRect: CGRect

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addEllipse(in: cropRect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

            Circle()
                .strokeBorder(Color.white.opacity(0.75), lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
        }
        .allowsHitTesting(false)
    }
}

private extension UIImage {
    func normalizedForAvatarCrop() -> UIImage {
        guard imageOrientation != .up || scale != 1 else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func cropped(to rect: CGRect) -> UIImage? {
        let normalizedRect = rect.standardized.integral
        guard normalizedRect.width > 0, normalizedRect.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: normalizedRect.size, format: format).image { _ in
            draw(at: CGPoint(x: -normalizedRect.minX, y: -normalizedRect.minY))
        }
    }
}
