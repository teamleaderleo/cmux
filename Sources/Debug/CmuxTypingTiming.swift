#if DEBUG
import AppKit

enum CmuxTypingTiming {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_TYPING_TIMING_LOGS"] == "1" || environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "cmuxTypingTimingLogs") || defaults.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    static let isVerboseProbeEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    private static let delayLogThresholdMs: Double = 6.0
    private static let durationLogThresholdMs: Double = 1.0

    @inline(__always)
    static func start() -> TimeInterval? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.systemUptime
    }

    @inline(__always)
    static func logEventDelay(path: String, event: NSEvent) {
        guard isEnabled else { return }
        guard event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        guard shouldLog(delayMs: delayMs, elapsedMs: nil) else { return }
        cmuxDebugLog("typing.delay probe=\(path) delayMs=\(format(delayMs)) \(eventFields(event))")
    }

    @inline(__always)
    static func logDuration(path: String, startedAt: TimeInterval?, event: NSEvent? = nil, extra: String? = nil) {
        CmuxMainThreadTurnProfiler.endMeasure(path, startedAt: startedAt)
        guard let startedAt else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        guard shouldLog(delayMs: delayMs, elapsedMs: elapsedMs) else { return }
        var line = "typing.timing probe=\(path) elapsedMs=\(format(elapsedMs))"
        if let event {
            line += " \(eventFields(event))"
            if let delayMs {
                line += " delayMs=\(format(delayMs))"
            }
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        cmuxDebugLog(line)
    }

    @inline(__always)
    static func logBreakdown(
        path: String,
        totalMs: Double,
        event: NSEvent? = nil,
        thresholdMs: Double = 2.0,
        parts: [(String, Double)],
        extra: String? = nil
    ) {
        guard isEnabled else { return }
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        let hasSlowPart = parts.contains { $0.1 >= thresholdMs }
        guard isVerboseProbeEnabled || totalMs >= thresholdMs || hasSlowPart || (delayMs ?? 0) >= delayLogThresholdMs else {
            return
        }
        var line = "typing.phase probe=\(path) totalMs=\(format(totalMs))"
        if let event {
            line += " \(eventFields(event))"
        }
        if let delayMs {
            line += " delayMs=\(format(delayMs))"
        }
        for (name, value) in parts where isVerboseProbeEnabled || value >= 0.05 {
            line += " \(name)=\(format(value))"
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        cmuxDebugLog(line)
    }

    @inline(__always)
    private static func eventFields(_ event: NSEvent) -> String {
        "eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)"
    }

    @inline(__always)
    private static func shouldLog(delayMs: Double?, elapsedMs: Double?) -> Bool {
        if isVerboseProbeEnabled {
            return true
        }
        if let delayMs, delayMs >= delayLogThresholdMs {
            return true
        }
        if let elapsedMs, elapsedMs >= durationLogThresholdMs {
            return true
        }
        return false
    }

    @inline(__always)
    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
#endif
