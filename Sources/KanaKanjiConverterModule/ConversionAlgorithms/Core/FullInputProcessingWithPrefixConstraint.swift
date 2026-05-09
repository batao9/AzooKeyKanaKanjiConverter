import Algorithms
import Foundation
import SwiftUtils

extension Kana2Kanji {
    func kana2lattice_all_with_prefix_constraint_from_seed(_ seed: FullInputLatticeSeed, N_best: Int, constraint: PrefixConstraint) -> (result: LatticeNode, lattice: Lattice) {
        let totalStart = enginePerfStart()
        let result: LatticeNode = LatticeNode.EOSNode
        let rawNodes = seed.makeRawNodes()
        let latticeBuildStart = enginePerfStart()
        let lattice: Lattice = Lattice(
            inputCount: seed.inputCount,
            surfaceCount: seed.surfaceCount,
            rawNodes: rawNodes
        )
        let latticeBuildMs = enginePerfMillis(since: latticeBuildStart)
        let traverseStart = enginePerfStart()
        var visitedNodeCount = 0
        var skippedEmptyPrevCount = 0
        var resultCheckCount = 0
        var resultConstraintSkipCount = 0
        var nextNodeVisitCount = 0
        var transitionCheckCount = 0
        var transitionConstraintSkipCount = 0
        var insertedTransitionCount = 0
        var candidateBuildMs = 0
        var candidateBuildCount = 0
        for (isHead, nodeArray) in lattice.indexedNodes(indices: seed.latticeIndices) {
            for node in nodeArray {
                visitedNodeCount += 1
                if node.prevs.isEmpty {
                    skippedEmptyPrevCount += 1
                    continue
                }
                let wValue: PValue = node.data.value()
                if isHead {
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                let nextIndex = seed.indexMap.dualIndex(for: node.range.endIndex)
                if nextIndex.surfaceIndex == seed.surfaceCount {
                    for index in node.prevs.indices {
                        resultCheckCount += 1
                        let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
                        if node.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            let utf8Text = newnode.getCandidateData().data.reduce(into: []) { $0.append(contentsOf: $1.word.utf8)} + node.data.word.utf8
                            let condition = (!constraint.hasEOS && utf8Text.hasPrefix(constraint.constraint)) || (constraint.hasEOS && utf8Text == constraint.constraint)
                            guard condition else {
                                resultConstraintSkipCount += 1
                                continue
                            }
                        }
                        result.prevs.append(newnode)
                    }
                } else {
                    let candidateBuildStart = enginePerfStart()
                    let candidates: [[String.UTF8View.Element]] = node.getCandidateData().map {
                        Array(($0.data.reduce(into: "") { $0.append(contentsOf: $1.word)} + node.data.word).utf8)
                    }
                    candidateBuildMs += enginePerfMillis(since: candidateBuildStart)
                    candidateBuildCount += candidates.count
                    for nextnode in lattice[index: nextIndex] {
                        nextNodeVisitCount += 1
                        let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                        for (index, value) in node.values.enumerated() {
                            transitionCheckCount += 1
                            if nextnode.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                                let utf8Text = candidates[index] + nextnode.data.word.utf8
                                let condition = (!constraint.hasEOS && (utf8Text.hasPrefix(constraint.constraint) || constraint.constraint.hasPrefix(utf8Text))) || (constraint.hasEOS && utf8Text.count < constraint.constraint.count && constraint.constraint.hasPrefix(utf8Text))
                                guard condition else {
                                    transitionConstraintSkipCount += 1
                                    continue
                                }
                            }
                            let newValue: PValue = ccValue + value
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            nextnode.prevs.insert(newnode, at: lastindex)
                            insertedTransitionCount += 1
                        }
                    }
                }
            }
        }
        let traverseMs = enginePerfMillis(since: traverseStart)
        KanaKanjiConverterEnginePerfLog.emit(
            "kana2lattice_all_with_prefix_constraint_seeded total_ms=\(enginePerfMillis(since: totalStart)) index_ms=0 lookup_ms=0 seed_index_ms=\(seed.indexMs) seed_lookup_ms=\(seed.lookupMs) lattice_build_ms=\(latticeBuildMs) traverse_ms=\(traverseMs) candidate_build_ms=\(candidateBuildMs) input_count=\(seed.inputCount) surface_count=\(seed.surfaceCount) constraint_bytes=\(constraint.constraint.count) constraint_has_eos=\(constraint.hasEOS) lattice_index_count=\(seed.latticeIndices.count) raw_node_count=\(seed.rawNodeCount) visited_node_count=\(visitedNodeCount) skipped_empty_prev_count=\(skippedEmptyPrevCount) result_check_count=\(resultCheckCount) result_constraint_skip_count=\(resultConstraintSkipCount) next_node_visit_count=\(nextNodeVisitCount) transition_check_count=\(transitionCheckCount) transition_constraint_skip_count=\(transitionConstraintSkipCount) inserted_transition_count=\(insertedTransitionCount) candidate_build_count=\(candidateBuildCount) result_prev_count=\(result.prevs.count) n_best=\(N_best)"
        )
        return (result: result, lattice: lattice)
    }

    /// カナを漢字に変換する関数, 前提はなくかな列が与えられた場合。
    /// - Parameters:
    ///   - inputData: 入力データ。
    ///   - N_best: N_best。
    /// - Returns:
    ///   変換候補。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、追加された一文字に繋がるノードを列挙する。
    ///
    /// (2)次に、計算済みノードから、(1)で求めたノードにつながるようにregisterして、N_bestを求めていく。
    ///
    /// (3)(1)のregisterされた結果をresultノードに追加していく。この際EOSとの連接計算を行っておく。
    ///
    /// (4)ノードをアップデートした上で返却する。
    func kana2lattice_all_with_prefix_constraint(_ inputData: ComposingText, N_best: Int, constraint: PrefixConstraint) -> (result: LatticeNode, lattice: Lattice) {
        let totalStart = enginePerfStart()
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)。制約は\(constraint)")
        let result: LatticeNode = LatticeNode.EOSNode
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexStart = enginePerfStart()
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let indexMs = enginePerfMillis(since: indexStart)
        let lookupStart = enginePerfStart()
        let rawNodes = latticeIndices.map { index in
            let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                (iIndex, nil)
            } else {
                nil
            }
            let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                (sIndex, nil)
            } else {
                nil
            }
            return dicdataStore.lookupDicdata(
                composingText: inputData,
                inputRange: inputRange,
                surfaceRange: surfaceRange,
                needTypoCorrection: false
            )
        }
        let lookupMs = enginePerfMillis(since: lookupStart)
        let rawNodeCount = rawNodes.reduce(0) { $0 + $1.count }
        let latticeBuildStart = enginePerfStart()
        let lattice: Lattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: rawNodes
        )
        let latticeBuildMs = enginePerfMillis(since: latticeBuildStart)
        let traverseStart = enginePerfStart()
        var visitedNodeCount = 0
        var skippedEmptyPrevCount = 0
        var resultCheckCount = 0
        var resultConstraintSkipCount = 0
        var nextNodeVisitCount = 0
        var transitionCheckCount = 0
        var transitionConstraintSkipCount = 0
        var insertedTransitionCount = 0
        var candidateBuildMs = 0
        var candidateBuildCount = 0
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                visitedNodeCount += 1
                if node.prevs.isEmpty {
                    skippedEmptyPrevCount += 1
                    continue
                }
                // 生起確率を取得する。
                let wValue: PValue = node.data.value()
                if isHead {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 変換した文字数
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                // 文字数がcountと等しい場合登録する
                if nextIndex.surfaceIndex == surfaceCount {
                    for index in node.prevs.indices {
                        resultCheckCount += 1
                        let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
                        // 学習データやユーザ辞書由来の場合は素通しする
                        if node.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            let utf8Text = newnode.getCandidateData().data.reduce(into: []) { $0.append(contentsOf: $1.word.utf8)} + node.data.word.utf8
                            // 最終チェック
                            let condition = (!constraint.hasEOS && utf8Text.hasPrefix(constraint.constraint)) || (constraint.hasEOS && utf8Text == constraint.constraint)
                            guard condition else {
                                resultConstraintSkipCount += 1
                                continue
                            }
                        }
                        result.prevs.append(newnode)
                    }
                } else {
                    let candidateBuildStart = enginePerfStart()
                    let candidates: [[String.UTF8View.Element]] = node.getCandidateData().map {
                        Array(($0.data.reduce(into: "") { $0.append(contentsOf: $1.word)} + node.data.word).utf8)
                    }
                    candidateBuildMs += enginePerfMillis(since: candidateBuildStart)
                    candidateBuildCount += candidates.count
                    // nodeの繋がる次にあり得る全てのnextnodeに対して
                    for nextnode in lattice[index: nextIndex] {
                        nextNodeVisitCount += 1
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            transitionCheckCount += 1
                            // 制約を少なくとも満たしている必要がある
                            // common prefixが単語か制約のどちらかに一致している必要
                            // 制約 AB 単語 ABC (OK)
                            // 制約 AB 単語 A   (OK)
                            // 制約 AB 単語 AC  (NG)
                            // ただし、学習データやユーザ辞書由来の場合は素通しする
                            if nextnode.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                                let utf8Text = candidates[index] + nextnode.data.word.utf8
                                let condition = (!constraint.hasEOS && (utf8Text.hasPrefix(constraint.constraint) || constraint.constraint.hasPrefix(utf8Text))) || (constraint.hasEOS && utf8Text.count < constraint.constraint.count && constraint.constraint.hasPrefix(utf8Text))
                                guard condition else {
                                    transitionConstraintSkipCount += 1
                                    continue
                                }
                            }
                            let newValue: PValue = ccValue + value
                            // 追加すべきindexを取得する
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                            // カウントがオーバーしている場合は除去する
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            // removeしてからinsertした方が速い (insertはO(N)なので)
                            nextnode.prevs.insert(newnode, at: lastindex)
                            insertedTransitionCount += 1
                        }
                    }
                }
            }
        }
        let traverseMs = enginePerfMillis(since: traverseStart)
        KanaKanjiConverterEnginePerfLog.emit(
            "kana2lattice_all_with_prefix_constraint total_ms=\(enginePerfMillis(since: totalStart)) index_ms=\(indexMs) lookup_ms=\(lookupMs) lattice_build_ms=\(latticeBuildMs) traverse_ms=\(traverseMs) candidate_build_ms=\(candidateBuildMs) input_count=\(inputCount) surface_count=\(surfaceCount) constraint_bytes=\(constraint.constraint.count) constraint_has_eos=\(constraint.hasEOS) lattice_index_count=\(latticeIndices.count) raw_node_count=\(rawNodeCount) visited_node_count=\(visitedNodeCount) skipped_empty_prev_count=\(skippedEmptyPrevCount) result_check_count=\(resultCheckCount) result_constraint_skip_count=\(resultConstraintSkipCount) next_node_visit_count=\(nextNodeVisitCount) transition_check_count=\(transitionCheckCount) transition_constraint_skip_count=\(transitionConstraintSkipCount) inserted_transition_count=\(insertedTransitionCount) candidate_build_count=\(candidateBuildCount) result_prev_count=\(result.prevs.count) n_best=\(N_best)"
        )
        return (result: result, lattice: lattice)
    }

}
