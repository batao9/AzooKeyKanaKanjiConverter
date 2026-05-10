@testable import KanaKanjiConverterModule
import XCTest

final class FullInputLatticeSeedTests: XCTestCase {
    private func dictionaryURL() -> URL {
        Bundle.module.resourceURL!.standardizedFileURL.appendingPathComponent("DictionaryMock", isDirectory: true)
    }

    private func candidateTexts(_ result: LatticeNode, converter: Kana2Kanji) -> [String] {
        result.getCandidateData().map {
            converter.processClauseCandidate($0).text
        }
    }

    func testPrefixConstraintFromSeedMatchesLookupPath() throws {
        let store = DicdataStore(dictionaryURL: self.dictionaryURL())
        let converter = Kana2Kanji(dicdataStore: store)
        let state = store.prepareState()
        var inputData = ComposingText()
        inputData.insertAtCursorPosition("し", inputStyle: .direct)
        let constraint = Kana2Kanji.PrefixConstraint(Array("し".utf8))

        let normal = converter.kana2lattice_all_with_prefix_constraint(
            inputData,
            N_best: 3,
            constraint: constraint,
            dicdataStoreState: state
        )
        let seed = converter.makeFullInputLatticeSeed(
            inputData,
            needTypoCorrection: false,
            dicdataStoreState: state
        )
        let seeded = converter.kana2lattice_all_with_prefix_constraint_from_seed(
            seed,
            N_best: 3,
            constraint: constraint
        )

        let normalTexts = self.candidateTexts(normal.result, converter: converter)
        let seededTexts = self.candidateTexts(seeded.result, converter: converter)
        XCTAssertFalse(normalTexts.isEmpty)
        XCTAssertEqual(seededTexts, normalTexts)
    }
}
