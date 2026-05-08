import Foundation

public enum KanaKanjiConverterEnginePerfLog {
    public typealias Logger = @Sendable (String) -> Void

    nonisolated(unsafe) private static var logger: Logger?
    nonisolated(unsafe) private static var enabled = false

    public static func configure(enabled: Bool, logger: Logger?) {
        self.enabled = enabled
        self.logger = logger
    }

    package static func emit(_ message: @autoclosure () -> String) {
        guard enabled else {
            return
        }

        let resolvedMessage = message()
        if let logger {
            logger(resolvedMessage)
        } else {
            print("[ENGINE/PERF] \(resolvedMessage)")
        }
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

package func enginePerfMillis(since start: Double) -> Int {
    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
}
