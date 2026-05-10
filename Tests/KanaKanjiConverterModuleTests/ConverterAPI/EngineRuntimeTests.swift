@testable import KanaKanjiConverterModule
import XCTest

final class EngineRuntimeTests: XCTestCase {
    override func tearDown() {
        KanaKanjiConverterEngineRuntime.configure(gpuLayerCount: 0)
        super.tearDown()
    }

    func testGpuLayerCountIsClampedToNonNegativeValue() {
        KanaKanjiConverterEngineRuntime.configure(gpuLayerCount: -1)
        XCTAssertEqual(KanaKanjiConverterEngineRuntime.resolvedGpuLayerCount, 0)
    }

    func testGpuLayerCountCanRequestAllLayers() {
        KanaKanjiConverterEngineRuntime.configure(gpuLayerCount: Int32.max)
        XCTAssertEqual(KanaKanjiConverterEngineRuntime.resolvedGpuLayerCount, Int32.max)
    }
}
