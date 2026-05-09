import Algorithms
import Foundation
import SwiftUtils
import EfficientNGram

extension Kana2Kanji {
    struct ZenzaiCache: Sendable {
        init(_ inputData: ComposingText, constraint: PrefixConstraint, satisfyingCandidate: Candidate?) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
        }

        private var prefixConstraint: PrefixConstraint
        private var satisfyingCandidate: Candidate?
        private var inputData: ComposingText

        func getNewConstraint(for newInputData: ComposingText) -> PrefixConstraint {
            if let satisfyingCandidate {
                var current = newInputData.convertTarget.toKatakana()[...]
                var constraint = [UInt8]()
                for item in satisfyingCandidate.data {
                    if current.hasPrefix(item.ruby) {
                        constraint += item.word.utf8
                        current = current.dropFirst(item.ruby.count)
                    }
                }
                return PrefixConstraint(constraint)
            } else if newInputData.convertTarget.hasPrefix(inputData.convertTarget) {
                return self.prefixConstraint
            } else {
                return PrefixConstraint([])
            }
        }
    }

    struct PrefixConstraint: Sendable, Equatable, Hashable, CustomStringConvertible {
        init(_ constraint: [UInt8], hasEOS: Bool = false) {
            self.constraint = constraint
            self.hasEOS = hasEOS
        }

        var constraint: [UInt8]
        var hasEOS: Bool

        var description: String {
            "PrefixConstraint(constraint: \"\(String(decoding: self.constraint, as: UTF8.self))\", hasEOS: \(self.hasEOS))"
        }

        var isEmpty: Bool {
            self.constraint.isEmpty && !self.hasEOS
        }
    }

    /// zenzaiシステムによる完全変換。
    @MainActor func all_zenzai(
        _ inputData: ComposingText,
        zenz: Zenz,
        zenzaiCache: ZenzaiCache?,
        inferenceLimit: Int,
        requestRichCandidates: Bool,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> (result: LatticeNode, lattice: Lattice, cache: ZenzaiCache) {
        let totalStart = ProcessInfo.processInfo.systemUptime
        let constraintStart = ProcessInfo.processInfo.systemUptime
        var constraint = zenzaiCache?.getNewConstraint(for: inputData) ?? PrefixConstraint([])
        let constraintMs = enginePerfMillis(since: constraintStart)
        KanaKanjiConverterEnginePerfLog.emit(
            "all_zenzai start input_count=\(inputData.input.count) surface_count=\(inputData.convertTarget.count) initial_constraint_bytes=\(constraint.constraint.count) initial_constraint_has_eos=\(constraint.hasEOS) had_cache=\(zenzaiCache != nil) constraint_ms=\(constraintMs) inference_limit=\(inferenceLimit) rich=\(requestRichCandidates)"
        )
        debug("initial constraint", constraint)
        let eosNode = LatticeNode.EOSNode
        var lattice: Lattice = Lattice()
        var constructedCandidates: [(RegisteredNode, Candidate)] = []
        var insertedCandidates: [(RegisteredNode, Candidate)] = []
        defer {
            eosNode.prevs = insertedCandidates.map(\.0)
        }
        var inferenceLimit = inferenceLimit
        while true {
            let draftStart = ProcessInfo.processInfo.systemUptime
            let constraintWasEmpty = constraint.isEmpty
            let latticeStart = ProcessInfo.processInfo.systemUptime
            let draftResult = if constraint.isEmpty {
                // 全部を変換する場合はN=2の変換を行う
                // 実験の結果、ここは2-bestを取ると平均的な速度が最良になることがわかったので、そうしている。
                self.kana2lattice_all(inputData, N_best: 2, needTypoCorrection: false)
            } else {
                // 制約がついている場合は高速になるので、N=3としている
                self.kana2lattice_all_with_prefix_constraint(inputData, N_best: 3, constraint: constraint)
            }
            let latticeMs = enginePerfMillis(since: latticeStart)
            if lattice.isEmpty {
                // 初回のみ
                lattice = draftResult.lattice
            }
            let candidateDataStart = ProcessInfo.processInfo.systemUptime
            let candidateData = draftResult.result.getCandidateData()
            let candidateDataMs = enginePerfMillis(since: candidateDataStart)
            let processCandidateStart = ProcessInfo.processInfo.systemUptime
            let candidates = candidateData.map(self.processClauseCandidate)
            let processCandidateMs = enginePerfMillis(since: processCandidateStart)
            KanaKanjiConverterEnginePerfLog.emit(
                "all_zenzai draft elapsed_ms=\(enginePerfMillis(since: draftStart)) lattice_ms=\(latticeMs) candidate_data_ms=\(candidateDataMs) process_candidate_ms=\(processCandidateMs) constraint_empty=\(constraintWasEmpty) constraint_bytes=\(constraint.constraint.count) result_prev_count=\(draftResult.result.prevs.count) candidate_data_count=\(candidateData.count) candidate_count=\(candidates.count)"
            )
            constructedCandidates.append(contentsOf: zip(draftResult.result.prevs, candidates))
            let bestStart = ProcessInfo.processInfo.systemUptime
            var best: (Int, Candidate)?
            for (i, cand) in candidates.enumerated() {
                if let (_, c) = best, cand.value > c.value {
                    best = (i, cand)
                } else if best == nil {
                    best = (i, cand)
                }
            }
            let bestMs = enginePerfMillis(since: bestStart)
            KanaKanjiConverterEnginePerfLog.emit(
                "all_zenzai draft_select elapsed_ms=\(bestMs) candidate_count=\(candidates.count) has_best=\(best != nil)"
            )
            guard var (index, candidate) = best else {
                debug("best was not found!")
                // Emptyの場合
                // 制約が満たせない場合は無視する
                KanaKanjiConverterEnginePerfLog.emit(
                    "all_zenzai finish reason=no_best total_ms=\(enginePerfMillis(since: totalStart)) inserted_count=\(insertedCandidates.count)"
                )
                return (eosNode, lattice, ZenzaiCache(inputData, constraint: PrefixConstraint([]), satisfyingCandidate: nil))
            }

            debug("Constrained draft modeling", enginePerfMillis(since: draftStart))
            reviewLoop: while true {
                // resultsを更新
                // ここでN-Bestも並び変えていることになる
                insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 0)
                if inferenceLimit == 0 {
                    debug("inference limit! \(candidate.text) is used for excuse")
                    // When inference occurs more than maximum times, then just return result at this point
                    KanaKanjiConverterEnginePerfLog.emit(
                        "all_zenzai finish reason=inference_limit total_ms=\(enginePerfMillis(since: totalStart)) inserted_count=\(insertedCandidates.count) final_constraint_bytes=\(constraint.constraint.count) final_constraint_has_eos=\(constraint.hasEOS)"
                    )
                    return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: candidate))
                }
                let reviewStart = ProcessInfo.processInfo.systemUptime
                let reviewResult = zenz.candidateEvaluate(
                    convertTarget: inputData.convertTarget,
                    candidates: [candidate],
                    requestRichCandidates: requestRichCandidates,
                    personalizationMode: personalizationMode,
                    versionDependentConfig: versionDependentConfig
                )
                KanaKanjiConverterEnginePerfLog.emit(
                    "all_zenzai review elapsed_ms=\(enginePerfMillis(since: reviewStart)) candidate_text_count=\(candidate.text.count) candidate_ruby_count=\(candidate.rubyCount) remaining_inference_limit_before_decrement=\(inferenceLimit) result=\(reviewResult.perfLabel)"
                )
                inferenceLimit -= 1
                let nextAction = self.review(
                    candidateIndex: index,
                    candidates: candidates,
                    reviewResult: reviewResult,
                    constraint: &constraint
                )
                switch nextAction {
                case .return(let constraint, let alternativeConstraints, let satisfied):
                    if requestRichCandidates {
                        // alternativeConstraintsに従い、insertedCandidatesにデータを追加する
                        for alternativeConstraint in alternativeConstraints.reversed() where alternativeConstraint.probabilityRatio > 0.25 {
                            // constructed candidatesのうちalternativeConstraint.prefixConstraintを満たすものを列挙する
                            let mostLiklyCandidate = constructedCandidates.filter {
                                $0.1.text.utf8.hasPrefix(alternativeConstraint.prefixConstraint)
                            }.max {
                                $0.1.value < $1.1.value
                            }
                            if let mostLiklyCandidate {
                                // 0番目は最良候補
                                insertedCandidates.insert(mostLiklyCandidate, at: 1)
                            } else if alternativeConstraint.probabilityRatio > 0.5 {
                                // 十分に高い確率の場合、変換器を実際に呼び出して候補を作ってもらう
                                let draftResult = self.kana2lattice_all_with_prefix_constraint(inputData, N_best: 3, constraint: PrefixConstraint(alternativeConstraint.prefixConstraint))
                                let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
                                let best: (Int, Candidate)? = candidates.enumerated().reduce(into: nil) { best, pair in
                                    if let (_, c) = best, pair.1.value > c.value {
                                        best = pair
                                    } else if best == nil {
                                        best = pair
                                    }
                                }
                                if let (index, candidate) = best {
                                    insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 1)
                                }
                            }
                        }
                    }
                    if satisfied {
                        KanaKanjiConverterEnginePerfLog.emit(
                            "all_zenzai finish reason=satisfied total_ms=\(enginePerfMillis(since: totalStart)) inserted_count=\(insertedCandidates.count) final_constraint_bytes=\(constraint.constraint.count) final_constraint_has_eos=\(constraint.hasEOS)"
                        )
                        return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: candidate))
                    } else {
                        KanaKanjiConverterEnginePerfLog.emit(
                            "all_zenzai finish reason=unsatisfied total_ms=\(enginePerfMillis(since: totalStart)) inserted_count=\(insertedCandidates.count) final_constraint_bytes=\(constraint.constraint.count) final_constraint_has_eos=\(constraint.hasEOS)"
                        )
                        return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: nil))
                    }
                case .continue:
                    break reviewLoop
                case .retry(let candidateIndex):
                    index = candidateIndex
                    candidate = candidates[candidateIndex]
                }
            }
        }
    }

    private enum NextAction {
        case `return`(constraint: PrefixConstraint, alternativeConstraints: [ZenzContext.CandidateEvaluationResult.AlternativeConstraint], satisfied: Bool)
        case `continue`
        case `retry`(candidateIndex: Int)
    }

    private func review(
        candidateIndex: Int,
        candidates: [Candidate],
        reviewResult: consuming ZenzContext.CandidateEvaluationResult,
        constraint: inout PrefixConstraint,
    ) -> NextAction {
        switch reviewResult {
        case .error:
            // 何らかのエラーが発生
            debug("error")
            return .return(constraint: constraint, alternativeConstraints: [], satisfied: false)
        case .pass(let score, let alternativeConstraints):
            // 合格
            debug("passed:", score)
            return .return(constraint: constraint, alternativeConstraints: alternativeConstraints, satisfied: true)
        case .fixRequired(let prefixConstraint):
            // 同じ制約が2回連続で出てきたら諦める
            if constraint.constraint == prefixConstraint {
                debug("same constraint:", prefixConstraint)
                return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
            }
            // 制約が得られたので、更新する
            let isIncrementalUpdate = prefixConstraint.hasPrefix(constraint.constraint)
            constraint = PrefixConstraint(prefixConstraint)
            debug("update constraint:", constraint)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // この処理の正当性は、prefix constraintが漸進的に更新され、candidatesの構築時に可能な候補がすべて確認されたことに由来する
                // このため、学習候補などが最終ドラフトとして採択され、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if candidate.text.utf8.hasPrefix(prefixConstraint) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        case .wholeResult(let wholeConstraint):
            let newConstraint = PrefixConstraint(Array(wholeConstraint.utf8), hasEOS: true)
            // 同じ制約が2回連続で出てきたら諦める
            if constraint == newConstraint {
                debug("same constraint:", constraint)
                return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
            }
            // 制約が得られたので、更新する
            debug("update whole constraint:", wholeConstraint)
            let isIncrementalUpdate = wholeConstraint.utf8.hasPrefix(constraint.constraint)
            constraint = PrefixConstraint(Array(wholeConstraint.utf8), hasEOS: true)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // 上記と同様に、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if candidate.text == wholeConstraint && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        }
    }

    /// リトライの候補に対して恣意的なバリデーションを実施する
    private func heuristicRetryValidation(_ text: String) -> Bool {
        // 合成濁点・半濁点
        if text.unicodeScalars.contains("\u{3099}") || text.unicodeScalars.contains("\u{309A}") {
            return false
        }
        return true
    }
}
