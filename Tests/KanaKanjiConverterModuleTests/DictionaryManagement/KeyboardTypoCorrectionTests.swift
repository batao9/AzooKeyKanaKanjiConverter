@testable import KanaKanjiConverterModule
import XCTest

final class KeyboardTypoCorrectionTests: XCTestCase {
    private func composingText(_ keys: String, style: InputStyle = .roman2kana) -> ComposingText {
        var composingText = ComposingText()
        for key in keys {
            composingText.insertAtCursorPosition(String(key), inputStyle: style)
        }
        return composingText
    }

    private func generatedPrefixes(
        _ composingText: ComposingText
    ) -> [(text: String, provenance: KeyboardTypoCorrectionProvenance)] {
        let correction = KeyboardTypoCorrection(
            composingText: composingText,
            maxSpanLength: 20
        )
        guard var generator = correction.generator(
            range: .init(
                leftIndex: 0,
                rightIndexRange: 0 ..< composingText.convertTarget.count
            )
        ) else {
            return []
        }
        var result: [(text: String, provenance: KeyboardTypoCorrectionProvenance)] = []
        while let next = generator.next() {
            result.append((String(next.0), next.1.provenance))
        }
        return result
    }

    private func outputs(_ composingText: ComposingText) -> [String] {
        self.generatedPrefixes(composingText).map(\.text)
    }

    func testSmallTsuAddsCorrectedPrefix() {
        let prefixes = generatedPrefixes(composingText("kixtuxtute"))
        let corrected = prefixes.first { $0.text == "キッテ" }
        XCTAssertEqual(corrected?.provenance.kind, .smallTsu)
        XCTAssertEqual(corrected?.provenance.originalSurfaceRange, 0 ..< 4)
    }

    func testDoubleNnAddsConsonantAndVowelContinuations() {
        let roman = generatedPrefixes(composingText("konnnnitiha"))
        let corrected = roman.first { $0.text == "コンニチハ" }
        XCTAssertEqual(corrected?.provenance.kind, .doubleNn)
        XCTAssertEqual(corrected?.provenance.originalSurfaceRange, 0 ..< 6)

        XCTAssertTrue(outputs(composingText("こんんいちは")).contains("コンニチハ"))
    }

    func testRulesRejectTripleAndDirectKanaInputs() {
        XCTAssertTrue(outputs(composingText("kixtuxtuxtute")).isEmpty)
        XCTAssertTrue(outputs(composingText("あんんんたい", style: .direct)).isEmpty)
        XCTAssertTrue(outputs(composingText("きっって", style: .direct)).isEmpty)
    }

    func testRulesStayInsideRomanCompatibleInputRuns() {
        var romanThenDirect = composingText("kixtuxtute")
        romanThenDirect.insertAtCursorPosition("。", inputStyle: .direct)
        XCTAssertTrue(outputs(romanThenDirect).contains("キッテ"))

        var mixedTypo = composingText("ki")
        mixedTypo.insertAtCursorPosition("っって", inputStyle: .direct)
        XCTAssertFalse(outputs(mixedTypo).contains("キッテ"))

        XCTAssertTrue(outputs(composingText("きっって", style: .mapped(id: .defaultKanaJIS))).isEmpty)
    }

    func testDictionaryLookupRequiresOriginalRomanCompatibleSurface() {
        let roman = KeyboardTypoCorrection(
            composingText: composingText("simasuta"),
            maxSpanLength: 20
        )
        XCTAssertTrue(roman.allowsKeyboardTypoDictionaryLookup(start: 0, end: 3))
        XCTAssertTrue(roman.allowsKeyboardTypoDictionaryInputLookup(start: 0, end: 7))

        let directText = composingText("しますた", style: .direct)
        let direct = KeyboardTypoCorrection(
            composingText: directText,
            maxSpanLength: 20
        )
        XCTAssertFalse(direct.allowsKeyboardTypoDictionaryLookup(
            start: 0,
            end: directText.convertTarget.count - 1
        ))
        XCTAssertFalse(direct.allowsKeyboardTypoDictionaryInputLookup(
            start: 0,
            end: directText.input.count - 1
        ))
    }

    func testLookupSpanBoundsCorrectionPrecomputation() {
        let correction = KeyboardTypoCorrection(
            composingText: composingText("aaaaaaaaaaaaaaaaaaaaakixtuxtute"),
            maxSpanLength: 20
        )
        let generator = correction.generator(range: .init(leftIndex: 0, rightIndexRange: 0 ..< 20))
        XCTAssertNil(generator)
    }
}
