import Foundation

struct HTMLPlainTextNormalizer {
    func normalize(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        var output = html
        output = strip(pattern: "(?is)<script[^>]*>.*?</script>", in: output)
        output = strip(pattern: "(?is)<style[^>]*>.*?</style>", in: output)

        output = output
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(
                of: "(?i)</(p|div|li|tr|h1|h2|h3|h4|h5|h6)>",
                with: "\n",
                options: .regularExpression
            )

        output = strip(pattern: "(?is)<[^>]+>", in: output)
        output = decodeHTMLEntities(output)

        let lines = output
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private func strip(pattern: String, in value: String) -> String {
        value.replacingOccurrences(
            of: pattern,
            with: " ",
            options: .regularExpression
        )
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var output = value

        let fixedEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'")
        ]

        for (entity, replacement) in fixedEntities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }

        output = decodeNumericEntities(output, pattern: "&#([0-9]{1,7});", radix: 10)
        output = decodeNumericEntities(output, pattern: "&#x([0-9A-Fa-f]{1,6});", radix: 16)

        return output
    }

    private func decodeNumericEntities(_ value: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else {
            return value
        }

        var result = value
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let codeString = nsValue.substring(with: match.range(at: 1))
            guard let codePoint = UInt32(codeString, radix: radix),
                  let scalar = UnicodeScalar(codePoint) else {
                continue
            }
            let replacement = String(Character(scalar))
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }
}
