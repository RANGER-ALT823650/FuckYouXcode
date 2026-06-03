import UIKit
@preconcurrency import Vision

final class OCRService {
    func recognizeEnglishText(from image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if err != nil {
                    continuation.resume(returning: "")
                    return
                }
                let texts = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []

                let raw = texts.joined(separator: "\n")
                continuation.resume(returning: Self.postProcessNetflixStyleBrackets(raw))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        }
    }

    /// Fix a common OCR failure mode on subtitle screenshots:
    /// leading `[` is frequently misread as `l`, `i`, `I`, `1`, `|`.
    /// Requirement: if OCR output ends with `]`, assume it's a bracketed subtitle.
    /// Then ignore the first *misread* character and prepend `[`.
    private static func postProcessNetflixStyleBrackets(_ text: String) -> String {
        let misreads: Set<Character> = ["l", "i", "I", "1", "|"]

        return text
            .split(whereSeparator: \.isNewline)
            .map { lineSub in
                var line = String(lineSub).trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasSuffix("]") else { return line }

                // Already correct: [ ... ]
                if line.hasPrefix("[") { return line }

                // Remove the first non-space char if it's a common misread of '['.
                if let firstNonSpace = line.firstIndex(where: { !$0.isWhitespace }) {
                    let ch = line[firstNonSpace]
                    if misreads.contains(ch) {
                        line.remove(at: firstNonSpace)
                        line = line.trimmingCharacters(in: .whitespaces)
                    }
                }

                // Ensure it starts with '[' when it ends with ']'
                if !line.hasPrefix("[") {
                    line = "[" + line
                }
                return line
            }
            .joined(separator: "\n")
    }
}
