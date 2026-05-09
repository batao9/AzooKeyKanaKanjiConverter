//
//  all.swift
//  Keyboard
//
//  Created by ensan on 2020/09/14.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import Foundation
import SwiftUtils

struct FullInputLatticeSeed {
    struct NodeSeed {
        init(_ node: LatticeNode) {
            self.data = node.data
            self.range = node.range
            self.hasBOS = !node.prevs.isEmpty
        }

        let data: DicdataElement
        let range: Lattice.LatticeRange
        let hasBOS: Bool

        func makeNode() -> LatticeNode {
            let node = LatticeNode(data: self.data, range: self.range)
            if self.hasBOS {
                node.prevs.append(RegisteredNode.BOSNode())
            }
            return node
        }
    }

    let inputCount: Int
    let surfaceCount: Int
    let indexMap: LatticeDualIndexMap
    let latticeIndices: [LatticeDualIndexMap.DualIndex]
    let rawNodeSeeds: [[NodeSeed]]
    let indexMs: Int
    let lookupMs: Int
    let rawNodeCount: Int

    func makeRawNodes() -> [[LatticeNode]] {
        self.rawNodeSeeds.map { nodeSeeds in
            nodeSeeds.map { $0.makeNode() }
        }
    }
}

extension Kana2Kanji {
    func makeFullInputLatticeSeed(_ inputData: ComposingText, needTypoCorrection: Bool) -> FullInputLatticeSeed {
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
                needTypoCorrection: needTypoCorrection
            )
        }
        let lookupMs = enginePerfMillis(since: lookupStart)
        let rawNodeCount = rawNodes.reduce(0) { $0 + $1.count }
        let rawNodeSeeds = rawNodes.map { nodes in
            nodes.map(FullInputLatticeSeed.NodeSeed.init)
        }
        return FullInputLatticeSeed(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            indexMap: indexMap,
            latticeIndices: latticeIndices,
            rawNodeSeeds: rawNodeSeeds,
            indexMs: indexMs,
            lookupMs: lookupMs,
            rawNodeCount: rawNodeCount
        )
    }

    func kana2lattice_all_from_seed(_ seed: FullInputLatticeSeed, N_best: Int) -> (result: LatticeNode, lattice: Lattice) {
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
        var skippedRemovedCount = 0
        var resultUpdateCount = 0
        var nextUpdateCount = 0
        for (isHead, nodeArray) in lattice.indexedNodes(indices: seed.latticeIndices) {
            for node in nodeArray {
                visitedNodeCount += 1
                if node.prevs.isEmpty {
                    skippedEmptyPrevCount += 1
                    continue
                }
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
                    skippedRemovedCount += 1
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
                    resultUpdateCount += 1
                    self.updateResultNode(with: node, resultNode: result)
                } else {
                    nextUpdateCount += 1
                    self.updateNextNodes(with: node, nextNodes: lattice[index: nextIndex], nBest: N_best)
                }
            }
        }
        let traverseMs = enginePerfMillis(since: traverseStart)
        KanaKanjiConverterEnginePerfLog.emit(
            "kana2lattice_all_seeded total_ms=\(enginePerfMillis(since: totalStart)) index_ms=0 lookup_ms=0 seed_index_ms=\(seed.indexMs) seed_lookup_ms=\(seed.lookupMs) lattice_build_ms=\(latticeBuildMs) traverse_ms=\(traverseMs) input_count=\(seed.inputCount) surface_count=\(seed.surfaceCount) lattice_index_count=\(seed.latticeIndices.count) raw_node_count=\(seed.rawNodeCount) visited_node_count=\(visitedNodeCount) skipped_empty_prev_count=\(skippedEmptyPrevCount) skipped_removed_count=\(skippedRemovedCount) result_update_count=\(resultUpdateCount) next_update_count=\(nextUpdateCount) result_prev_count=\(result.prevs.count) n_best=\(N_best)"
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
    func kana2lattice_all(_ inputData: ComposingText, N_best: Int, needTypoCorrection: Bool) -> (result: LatticeNode, lattice: Lattice) {
        let totalStart = enginePerfStart()
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)")
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
                needTypoCorrection: needTypoCorrection
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
        var skippedRemovedCount = 0
        var resultUpdateCount = 0
        var nextUpdateCount = 0
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                visitedNodeCount += 1
                if node.prevs.isEmpty {
                    skippedEmptyPrevCount += 1
                    continue
                }
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
                    skippedRemovedCount += 1
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
                // 後続ノードのindex（正規化する）
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                // 文字数がcountと等しい場合登録する
                if nextIndex.surfaceIndex == surfaceCount {
                    resultUpdateCount += 1
                    self.updateResultNode(with: node, resultNode: result)
                } else {
                    nextUpdateCount += 1
                    self.updateNextNodes(with: node, nextNodes: lattice[index: nextIndex], nBest: N_best)
                }
            }
        }
        let traverseMs = enginePerfMillis(since: traverseStart)
        KanaKanjiConverterEnginePerfLog.emit(
            "kana2lattice_all total_ms=\(enginePerfMillis(since: totalStart)) index_ms=\(indexMs) lookup_ms=\(lookupMs) lattice_build_ms=\(latticeBuildMs) traverse_ms=\(traverseMs) input_count=\(inputCount) surface_count=\(surfaceCount) lattice_index_count=\(latticeIndices.count) raw_node_count=\(rawNodeCount) visited_node_count=\(visitedNodeCount) skipped_empty_prev_count=\(skippedEmptyPrevCount) skipped_removed_count=\(skippedRemovedCount) result_update_count=\(resultUpdateCount) next_update_count=\(nextUpdateCount) result_prev_count=\(result.prevs.count) n_best=\(N_best) typo=\(needTypoCorrection)"
        )
        return (result: result, lattice: lattice)
    }

    func updateResultNode(with node: LatticeNode, resultNode: LatticeNode) {
        for index in node.prevs.indices {
            let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
            resultNode.prevs.append(newnode)
        }
    }
    /// N-Best計算を高速に実行しつつ、遷移先ノードを更新する
    func updateNextNodes(with node: LatticeNode, nextNodes: some Sequence<LatticeNode>, nBest: Int) {
        for nextnode in nextNodes {
            if self.dicdataStore.shouldBeRemoved(data: nextnode.data) {
                continue
            }
            // クラスの連続確率を計算する。
            let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
            // nodeの持っている全てのprevnodeに対して
            for (index, value) in node.values.enumerated() {
                let newValue: PValue = ccValue + value
                // 追加すべきindexを取得する
                let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                if lastindex == nBest {
                    continue
                }
                let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                // カウントがオーバーしている場合は除去する
                if nextnode.prevs.count >= nBest {
                    nextnode.prevs.removeLast()
                }
                // removeしてからinsertした方が速い (insertはO(N)なので)
                nextnode.prevs.insert(newnode, at: lastindex)
            }
        }
    }
}
