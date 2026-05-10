import Foundation

public enum KanaKanjiConverterEngineRuntime {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var gpuLayerCount: Int32 = 0

        func configure(gpuLayerCount: Int32) {
            self.lock.lock()
            self.gpuLayerCount = max(0, gpuLayerCount)
            self.lock.unlock()
        }

        func resolvedGpuLayerCount() -> Int32 {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.gpuLayerCount
        }
    }

    nonisolated(unsafe) private static let state = State()

    public static func configure(gpuLayerCount: Int32) {
        self.state.configure(gpuLayerCount: gpuLayerCount)
    }

    package static var resolvedGpuLayerCount: Int32 {
        self.state.resolvedGpuLayerCount()
    }
}
