import SwiftUtils

/// Generates corrected dictionary lookup prefixes for two bounded roman-input
/// mistakes. The original surface generator remains active, so this only adds
/// alternative lattice nodes.
///
/// The SmallTSU and DoubleNN rule shapes are based on Mozc KeyCorrector:
/// https://github.com/google/mozc/blob/851c3fe33060d2a6090363e4d7ec44fafde2c03d/src/converter/key_corrector.cc
struct KeyboardTypoCorrection: Sendable {
    struct Prefix: Sendable {
        var characters: [Character]
        var originalEndIndex: Int
    }

    struct Generator: Sendable {
        private var prefixes: [Prefix]

        init(prefixes: [Prefix], range: TypoCorrectionGenerator.ProcessRange) {
            self.prefixes = prefixes.filter {
                range.rightIndexRange.contains($0.originalEndIndex)
            }.reversed()
        }

        mutating func setUnreachablePath<C: Collection<Character>>(target: C) {
            let target = Array(target)
            self.prefixes.removeAll { prefix in
                prefix.characters.starts(with: target)
            }
        }

        mutating func next() -> ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? {
            guard let prefix = self.prefixes.popLast() else {
                return nil
            }
            return (
                prefix.characters,
                (.surface(prefix.originalEndIndex), 0)
            )
        }
    }

    private let prefixesByStart: [[Prefix]]
    private let romanCompatibleSurfaceEnds: [Int?]
    private let romanCompatibleInputs: [Bool]

    init(composingText: ComposingText, maxSpanLength: Int) {
        guard maxSpanLength > 0,
              !composingText.input.isEmpty
        else {
            self.prefixesByStart = []
            self.romanCompatibleSurfaceEnds = []
            self.romanCompatibleInputs = []
            return
        }

        let surface = composingText.convertTarget.map { $0.toHiragana() }
        let compatibleEnds = if composingText.input.allSatisfy({
            Self.isRomanCompatible($0.inputStyle)
        }) {
            [Int?](repeating: surface.count, count: surface.count)
        } else {
            Self.keyboardCompatibleSurfaceEnds(
                composingText: composingText,
                surfaceCount: surface.count
            )
        }
        self.romanCompatibleSurfaceEnds = compatibleEnds
        self.romanCompatibleInputs = composingText.input.map {
            Self.isRomanCompatible($0.inputStyle)
        }
        self.prefixesByStart = surface.indices.map { start in
            guard let compatibleEnd = compatibleEnds[start] else {
                return []
            }
            return Self.correctedPrefixes(
                surface: surface,
                start: start,
                end: min(compatibleEnd, start + maxSpanLength)
            )
        }
    }

    /// Maps the converted surface back to input-style runs. Rewrites are only
    /// allowed inside roman-compatible runs and never cross direct kana,
    /// kana-layout, or frozen cursor-edit boundaries.
    private static func keyboardCompatibleSurfaceEnds(
        composingText: ComposingText,
        surfaceCount: Int
    ) -> [Int?] {
        var converted: [ComposingText.ConvertTargetElement] = []
        for element in composingText.input {
            ComposingText.updateConvertTargetElements(
                currentElements: &converted,
                newElement: element
            )
        }

        var ends = [Int?](repeating: nil, count: surfaceCount)
        var start = 0
        for element in converted {
            let end = min(surfaceCount, start + element.string.count)
            if Self.isRomanCompatible(element.inputStyle) {
                for index in start ..< end {
                    ends[index] = end
                }
            }
            start = end
        }
        return ends
    }

    private static func isRomanCompatible(_ inputStyle: InputStyle) -> Bool {
        switch inputStyle {
        case .roman2kana:
            true
        case .mapped(id: .defaultRomanToKana),
             .mapped(id: .defaultAZIK),
             .mapped(id: .tableName(_)):
            true
        case .direct,
             .mapped(id: .defaultKanaJIS),
             .mapped(id: .defaultKanaUS),
             .mapped(id: .empty):
            false
        }
    }

    func generator(range: TypoCorrectionGenerator.ProcessRange) -> Generator? {
        guard self.prefixesByStart.indices.contains(range.leftIndex) else {
            return nil
        }
        let prefixes = self.prefixesByStart[range.leftIndex]
        guard !prefixes.isEmpty else {
            return nil
        }
        return Generator(prefixes: prefixes, range: range)
    }

    func allowsKeyboardTypoDictionaryLookup(start: Int, end: Int) -> Bool {
        guard self.romanCompatibleSurfaceEnds.indices.contains(start),
              start <= end,
              let compatibleEnd = self.romanCompatibleSurfaceEnds[start]
        else {
            return false
        }
        return end < compatibleEnd
    }

    func allowsKeyboardTypoDictionaryInputLookup(start: Int, end: Int) -> Bool {
        guard self.romanCompatibleInputs.indices.contains(start),
              self.romanCompatibleInputs.indices.contains(end),
              start <= end
        else {
            return false
        }
        return self.romanCompatibleInputs[start ... end].allSatisfy { $0 }
    }

    private static func correctedPrefixes(
        surface: [Character],
        start: Int,
        end: Int
    ) -> [Prefix] {
        var output: [Character] = []
        var prefixes: [Prefix] = []
        var index = start
        var corrected = false

        while index < end {
            if !corrected,
               let rewrite = Self.rewrite(surface: surface, at: index, end: end)
            {
                output.append(contentsOf: rewrite.replacement)
                index += rewrite.consumedCount
                corrected = true
                prefixes.append(
                    Prefix(
                        characters: output.map { $0.toKatakana() },
                        originalEndIndex: index - 1
                    )
                )
                continue
            }

            output.append(surface[index])
            index += 1
            if corrected {
                prefixes.append(
                    Prefix(
                        characters: output.map { $0.toKatakana() },
                        originalEndIndex: index - 1
                    )
                )
            }
        }
        return prefixes
    }

    private static func rewrite(
        surface: [Character],
        at index: Int,
        end: Int
    ) -> (replacement: [Character], consumedCount: Int)? {
        guard index + 3 < end else {
            return nil
        }

        let first = surface[index]
        let second = surface[index + 1]
        let third = surface[index + 2]
        let fourth = surface[index + 3]

        // SmallTSU: ([^っ])っっ([^っ]) -> $1っ$2
        if Self.isHiragana(first), first != "っ",
           second == "っ", third == "っ",
           Self.isHiragana(fourth), fourth != "っ"
        {
            return ([first, "っ", fourth], 4)
        }

        // DoubleNN: ([^ん])んんX -> $1んX. A following vowel is folded
        // into this rule so the much broader NN rewrite remains disabled.
        if Self.isHiragana(first), first != "ん",
           second == "ん", third == "ん", fourth != "ん"
        {
            let continuation: Character = switch fourth {
            case "あ": "な"
            case "い": "に"
            case "う": "ぬ"
            case "え": "ね"
            case "お": "の"
            default: fourth
            }
            return ([first, "ん", continuation], 4)
        }

        return nil
    }

    private static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x3041 ... 0x3096).contains(scalar.value)
        }
    }
}
