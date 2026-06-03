import Foundation
import NaturalLanguage

enum WordNormalization {
    static func normalizeToken(_ token: String) -> String {
        var s = token.lowercased()
        s = s.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar) || scalar == "'"
        }.map(String.init).joined()
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return s
    }

    static func lemmatizeEnglish(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinContractions]
        let range = word.startIndex..<word.endIndex

        var lemmaResult: String?

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
            if let tag = tag {
                lemmaResult = tag.rawValue
            } else {
                lemmaResult = String(word[tokenRange])
            }
            return false
        }

        guard let lemma = lemmaResult?.lowercased(), !lemma.isEmpty else { return nil }
        return lemma
    }
}

enum WordExtractor {

    struct OrderedWord: Identifiable, Hashable {
        var id: String { word }
        let word: String
        let count: Int
        let firstIndex: Int   // 在原始文本中第一次出现的位置（用于排序）
    }

    // 你原来的：按频次统计（我保留）
    static func extractWords(from text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let tokens = tokenize(text)

        for t in tokens {
            let normalized = WordNormalization.normalizeToken(t)
            if normalized.count < 2 { continue }
            counts[normalized, default: 0] += 1
        }
        return counts
    }

    // ✅ 新增：按“出现先后”排序 + 去重（同时保留 count）
    static func extractOrderedWords(from text: String, useLemma: Bool = true) -> [OrderedWord] {
        let tokens = tokenize(text)

        var firstPos: [String: Int] = [:]
        var counts: [String: Int] = [:]

        // 这里用 token 的序号当“出现顺序”，性能稳定、足够符合“先后顺序”
        for (i, raw) in tokens.enumerated() {
            var w = WordNormalization.normalizeToken(raw)
            if w.count < 2 { continue }

            if useLemma, let lemma = WordNormalization.lemmatizeEnglish(w) {
                w = lemma
            }

            if firstPos[w] == nil {
                firstPos[w] = i
            }
            counts[w, default: 0] += 1
        }

        let result = counts.map { (word, count) in
            OrderedWord(word: word, count: count, firstIndex: firstPos[word] ?? Int.max)
        }
        .sorted { $0.firstIndex < $1.firstIndex }

        return result
    }

    // MARK: - Tokenize / Normalize

    private static func tokenize(_ text: String) -> [String] {
        // 用 NLTokenizer 比 split 更稳：能处理换行、标点、连字符等
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        return tokens
    }
}
