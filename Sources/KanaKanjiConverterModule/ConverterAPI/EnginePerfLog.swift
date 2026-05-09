import Foundation

public enum KanaKanjiConverterEnginePerfLog {
    public typealias Logger = @Sendable (String) -> Void

    nonisolated(unsafe) private static var logger: Logger?
    nonisolated(unsafe) private static var enabled = false

    public static func configure(enabled: Bool, logger: Logger?) {
        self.enabled = enabled
        self.logger = logger
    }

    package static var isEnabled: Bool {
        enabled
    }

    package static func emit(_ message: @autoclosure () -> String) {
        guard enabled, let logger else {
            return
        }

        logger(message())
    }
}

public enum KanaKanjiConverterEngineRuntime {
    nonisolated(unsafe) private static var gpuLayerCount: Int32 = 0

    public static func configure(gpuLayerCount: Int32) {
        self.gpuLayerCount = gpuLayerCount
    }

    package static var resolvedGpuLayerCount: Int32 {
        gpuLayerCount
    }
}

package func enginePerfStart() -> Double? {
    guard KanaKanjiConverterEnginePerfLog.isEnabled else {
        return nil
    }

    return ProcessInfo.processInfo.systemUptime
}

package func enginePerfMillis(since start: Double?) -> Int {
    guard let start else {
        return 0
    }

    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
}
