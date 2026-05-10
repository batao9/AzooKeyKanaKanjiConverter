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
        let data: DicdataElement
        let range: Lattice.LatticeRange
        let hasBOS: Bool

        init(_ node: LatticeNode) {
            self.data = node.data
            self.range = node.range
            self.hasBOS = !node.prevs.isEmpty
        }

        func makeNode() -> LatticeNode {
            let node = LatticeNode(data: self.data, range: self.range)
            if self.hasBOS {
                node.prevs.append(.BOSNode())
            }
            return node
        }
    }

    let inputCount: Int
    let surfaceCount: Int
    let indexMap: LatticeDualIndexMap
    let latticeIndices: [LatticeDualIndexMap.DualIndex]
    private let rawNodeSeeds: [[NodeSeed]]

    init(
        inputCount: Int,
        surfaceCount: Int,
        indexMap: LatticeDualIndexMap,
        latticeIndices: [LatticeDualIndexMap.DualIndex],
        rawNodes: [[LatticeNode]]
    ) {
        self.inputCount = inputCount
        self.surfaceCount = surfaceCount
        self.indexMap = indexMap
        self.latticeIndices = latticeIndices
        self.rawNodeSeeds = rawNodes.map { nodes in
            nodes.map(NodeSeed.init)
        }
    }

    func makeRawNodes() -> [[LatticeNode]] {
        self.rawNodeSeeds.map { nodes in
            nodes.map { $0.makeNode() }
        }
    }

    func makeLattice() -> Lattice {
        Lattice(
            inputCount: self.inputCount,
            surfaceCount: self.surfaceCount,
            rawNodes: self.makeRawNodes()
        )
    }
}

extension Kana2Kanji {
    func makeFullInputLatticeSeed(
        _ inputData: ComposingText,
        needTypoCorrection: Bool,
        dicdataStoreState: DicdataStoreState
    ) -> FullInputLatticeSeed {
        self.makeFullInputLatticeSeedAndLattice(
            inputData,
            needTypoCorrection: needTypoCorrection,
            dicdataStoreState: dicdataStoreState
        ).seed
    }

    func makeFullInputLatticeSeedAndLattice(
        _ inputData: ComposingText,
        needTypoCorrection: Bool,
        dicdataStoreState: DicdataStoreState
    ) -> (seed: FullInputLatticeSeed, lattice: Lattice) {
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let rawNodes = self.lookupFullInputRawNodes(
            inputData,
            latticeIndices: latticeIndices,
            needTypoCorrection: needTypoCorrection,
            dicdataStoreState: dicdataStoreState
        )
        let seed = FullInputLatticeSeed(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            indexMap: indexMap,
            latticeIndices: latticeIndices,
            rawNodes: rawNodes
        )
        let lattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: rawNodes
        )
        return (seed: seed, lattice: lattice)
    }

    private func lookupFullInputRawNodes(
        _ inputData: ComposingText,
        latticeIndices: [LatticeDualIndexMap.DualIndex],
        needTypoCorrection: Bool,
        dicdataStoreState: DicdataStoreState
    ) -> [[LatticeNode]] {
        latticeIndices.map { index in
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
                needTypoCorrection: needTypoCorrection,
                state: dicdataStoreState
            )
        }
    }

    func kana2lattice_all_from_seed(_ seed: FullInputLatticeSeed, N_best: Int) -> (result: LatticeNode, lattice: Lattice) {
        self.kana2lattice_all_from_seed(seed, lattice: seed.makeLattice(), N_best: N_best)
    }

    func kana2lattice_all_from_seed(_ seed: FullInputLatticeSeed, lattice: Lattice, N_best: Int) -> (result: LatticeNode, lattice: Lattice) {
        let result = self.traverseFullInputLattice(
            lattice,
            N_best: N_best,
            indexMap: seed.indexMap,
            latticeIndices: seed.latticeIndices,
            surfaceCount: seed.surfaceCount
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
    func kana2lattice_all(
        _ inputData: ComposingText,
        N_best: Int,
        needTypoCorrection: Bool,
        preprocessedLattice: Lattice? = nil,
        dicdataStoreState: DicdataStoreState
    ) -> (result: LatticeNode, lattice: Lattice) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)")
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let lattice: Lattice
        if let preprocessedLattice {
            lattice = preprocessedLattice
        } else {
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
                    needTypoCorrection: needTypoCorrection,
                    state: dicdataStoreState
                )
            }
            lattice = Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }
        // 「i文字目から始まるnodes」に対して
        let result = self.traverseFullInputLattice(
            lattice,
            N_best: N_best,
            indexMap: indexMap,
            latticeIndices: latticeIndices,
            surfaceCount: surfaceCount
        )
        return (result: result, lattice: lattice)
    }

    private func traverseFullInputLattice(
        _ lattice: Lattice,
        N_best: Int,
        indexMap: LatticeDualIndexMap,
        latticeIndices: [LatticeDualIndexMap.DualIndex],
        surfaceCount: Int
    ) -> LatticeNode {
        let result: LatticeNode = LatticeNode.EOSNode
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
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
                    self.updateResultNode(with: node, resultNode: result)
                } else {
                    self.updateNextNodes(with: node, nextNodes: lattice[index: nextIndex], nBest: N_best)
                }
            }
        }
        return result
    }

    func updateResultNode(with node: LatticeNode, resultNode: LatticeNode) {
        for index in node.prevs.indices {
            let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
            resultNode.prevs.append(newnode)
        }
    }
    /// N-Best計算を高速に実行しつつ、遷移先ノードを更新する
    func updateNextNodes(with node: LatticeNode, nextNodes: some Sequence<LatticeNode>, nBest: Int) {
        let ccLatter = self.dicdataStore.getCCLatter(node.data.rcid)
        for nextnode in nextNodes {
            if self.dicdataStore.shouldBeRemoved(data: nextnode.data) {
                continue
            }
            // クラスの連続確率を計算する。
            let ccValue: PValue = ccLatter.get(nextnode.data.lcid)
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
