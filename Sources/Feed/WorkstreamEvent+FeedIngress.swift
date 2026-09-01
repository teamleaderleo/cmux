import CMUXAgentLaunch
import Darwin

/// App-internal evidence captured when a Feed event first reaches cmux.
///
/// The wire payload only carries `_ppid`. A numeric PID can be reused after the
/// emitting process exits, so downstream consumers must not reconstruct process
/// identity from that integer after ingress. This envelope snapshots the kernel
/// birth identity once and carries it beside any later authoritative/re-homed
/// copy of the event. It is an in-process Swift type and cannot be supplied by a
/// hook payload.
struct FeedIngressProcessGenerationEvent: Sendable {
    let event: WorkstreamEvent
    let processIdentity: AgentPIDProcessIdentity?

    init(event: WorkstreamEvent) {
        self.event = event
        guard
            let ppid = event.ppid,
            let pid = pid_t(exactly: ppid)
        else {
            self.processIdentity = nil
            return
        }
        self.processIdentity = AgentPIDProcessIdentity(pid: pid)
    }

    private init(
        event: WorkstreamEvent,
        processIdentity: AgentPIDProcessIdentity?
    ) {
        self.event = event
        self.processIdentity = processIdentity
    }

    func replacingEvent(_ event: WorkstreamEvent) -> Self {
        Self(event: event, processIdentity: processIdentity)
    }
}

extension WorkstreamEvent {
    /// Returns an internal process-generation envelope only for process-bound
    /// hook events. If the process has already exited, the envelope is retained
    /// with a nil identity so consumers can fail closed instead of falling back
    /// to the logical session id.
    var feedIngressProcessGenerationEvent: FeedIngressProcessGenerationEvent? {
        guard ppid != nil else { return nil }
        return FeedIngressProcessGenerationEvent(event: self)
    }

    var feedIngressDeliveryKey: FeedIngressDeliveryKey {
        FeedIngressDeliveryKey(
            source: source,
            sessionId: sessionId
        )
    }

    var zeroWaitFeedIngressImportance: FeedIngressDeliveryImportance {
        switch hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .stop,
             .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            // These establish authoritative session phase or needs-input state that cannot be
            // reconstructed from a later high-volume tool telemetry event.
            return .sessionCritical
        case .preToolUse, .postToolUse, .postToolUseFailure, .todoWrite,
             .subagentStart, .subagentStop, .preCompact, .postCompact:
            // Tool traffic is best-effort; prompt submission establishes working
            // state, while compaction/subagent events preserve the parent state.
            return .ordinary
        }
    }
}
