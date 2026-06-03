import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct InstructionView: View {
    init() {
#if canImport(UIKit)
        UIPageControl.appearance().currentPageIndicatorTintColor = UIColor.label
        UIPageControl.appearance().pageIndicatorTintColor = UIColor.secondaryLabel.withAlphaComponent(0.45)
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            TabView {
                InstructionStepOneView(pageHeight: proxy.size.height, pageWidth: proxy.size.width)
                InstructionStepTwoView(pageHeight: proxy.size.height, pageWidth: proxy.size.width)
                InstructionStepThreeView(pageHeight: proxy.size.height, pageWidth: proxy.size.width)
                InstructionStepFourView(pageHeight: proxy.size.height, pageWidth: proxy.size.width)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Color(.systemBackground))
        }
        .ignoresSafeArea(edges: .bottom)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstructionStepOneView: View {
    let pageHeight: CGFloat
    let pageWidth: CGFloat

    var body: some View {
        InstructionPageContentView(
            imageName: "IMG_3221",
            markdownFileName: "InstructionStep1",
            pageHeight: pageHeight,
            pageWidth: pageWidth
        )
    }
}

private struct InstructionStepTwoView: View {
    let pageHeight: CGFloat
    let pageWidth: CGFloat

    var body: some View {
        InstructionPageContentView(
            imageName: "IMG_3222",
            markdownFileName: "InstructionStep2",
            pageHeight: pageHeight,
            pageWidth: pageWidth
        )
    }
}

private struct InstructionStepThreeView: View {
    let pageHeight: CGFloat
    let pageWidth: CGFloat

    var body: some View {
        InstructionPageContentView(
            imageName: "IMG_3224",
            markdownFileName: "InstructionStep3",
            pageHeight: pageHeight,
            pageWidth: pageWidth
        )
    }
}

private struct InstructionStepFourView: View {
    let pageHeight: CGFloat
    let pageWidth: CGFloat

    var body: some View {
        InstructionPageContentView(
            imageName: "IMG_3225",
            markdownFileName: "InstructionStep4",
            pageHeight: pageHeight,
            pageWidth: pageWidth
        )
    }
}

private struct InstructionPageContentView: View {
    let imageName: String
    let markdownFileName: String
    let pageHeight: CGFloat
    let pageWidth: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                instructionImage(maxHeight: pageHeight * 0.5)

                markdownContentView(fileName: markdownFileName)
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 4)
        }
    }

    private func instructionImage(maxHeight: CGFloat) -> some View {
        let aspectRatio = imageAspectRatio(named: imageName)
        let maxImageWidth = max(pageWidth - 32, 0)
        let widthIfMaxHeight = maxHeight * aspectRatio
        let imageWidth = min(maxImageWidth, widthIfMaxHeight)
        let imageHeight = imageWidth / aspectRatio

        return Image(imageName)
            .resizable()
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.42), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func markdownContentView(fileName: String) -> some View {
        let lines = loadMarkdownLines(named: fileName)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line.kind {
                case .heading(let level, let text):
                    Text(inlineMarkdownAttributedString(from: text))
                        .font(headingFont(for: level))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .body(let text):
                    Text(inlineMarkdownAttributedString(from: text))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .blank:
                    Color.clear
                        .frame(height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 80, alignment: .topLeading)
        .multilineTextAlignment(.leading)
    }

    private func loadMarkdownLines(named fileName: String) -> [MarkdownDisplayLine] {
        guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: "md"),
              let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [.init(kind: .body(text: ""))]
        }

        let parsedLines = markdown
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { parseMarkdownLine(String($0)) }

        if parsedLines.isEmpty {
            return [.init(kind: .body(text: ""))]
        }

        return parsedLines
    }

    private func parseMarkdownLine(_ rawLine: String) -> MarkdownDisplayLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return .init(kind: .blank)
        }

        if let heading = headingInfo(from: trimmed) {
            return .init(kind: .heading(level: heading.level, text: heading.text))
        }

        return .init(kind: .body(text: trimmed))
    }

    private func headingInfo(from line: String) -> (level: Int, text: String)? {
        var index = line.startIndex
        var level = 0

        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0 else {
            return nil
        }

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let title = String(line[index...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            return nil
        }

        return (level: level, text: title)
    }

    private func inlineMarkdownAttributedString(from text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }

        return AttributedString(text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }

    private func imageAspectRatio(named name: String) -> CGFloat {
#if canImport(UIKit)
        if let image = UIImage(named: name), image.size.height > 0 {
            return image.size.width / image.size.height
        }
#endif
        return 1
    }
}

private struct MarkdownDisplayLine {
    enum Kind {
        case heading(level: Int, text: String)
        case body(text: String)
        case blank
    }

    let kind: Kind
}
