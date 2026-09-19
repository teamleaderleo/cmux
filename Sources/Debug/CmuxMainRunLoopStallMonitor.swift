#if DEBUG
import AppKit

final class CmuxMainRunLoopStallMonitor {
    static let shared = CmuxMainRunLoopStallMonitor()

    private let thresholdMs: Double = 8.0
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var lastActivity: CFRunLoopActivity?
    private var lastTimestamp: TimeInterval?

    private init() {}

    func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let monitor = Unmanaged<CmuxMainRunLoopStallMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastActivity = activity
            lastTimestamp = now
        }

        guard let lastActivity, let lastTimestamp else { return }
        let elapsedMs = max(0, (now - lastTimestamp) * 1000.0)
        guard elapsedMs >= thresholdMs else { return }
        if lastActivity == .beforeWaiting && activity == .afterWaiting {
            return
        }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let currentEvent = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        cmuxDebugLog(
            "runloop.stall gapMs=\(String(format: "%.2f", elapsedMs)) prev=\(label(for: lastActivity)) " +
            "next=\(label(for: activity)) mode=\(mode) firstResponder=\(firstResponder) \(currentEvent)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}
#endif
