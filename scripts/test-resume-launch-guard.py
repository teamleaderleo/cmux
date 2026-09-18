"""Execute the production launch guard without building the full app test host."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
out = root / '.glaeda/sidebar-lab/launch-guard-check'
out.mkdir(parents=True, exist_ok=True)
# The identity helper is pure Foundation; its subsequent app-binding extension
# needs the full application. Keep the exact production helper for this harness.
identity = (root / 'Sources/SurfaceResumeBindingSnapshot+ManagedSessionIdentity.swift').read_text().split('extension SurfaceResumeBindingSnapshot {', 1)[0]
guard = (root / 'Sources/AgentResumeLaunchGuard.swift').read_text()
runner = r'''
@main struct LaunchGuardCheck {
    @MainActor static func main() {
        var now = Date(timeIntervalSince1970: 100)
        let state = AgentResumeLaunchGuard(dateProvider: { now })
        let first = UUID(), second = UUID()
        let old = state.claimResumeLaunchWithToken(kind: "codex", sessionId: "one", ownerPanelID: first)!
        precondition(state.claimResumeLaunchWithToken(kind: "codex", sessionId: "one", ownerPanelID: second) == nil)
        precondition(state.claimResumeLaunchWithToken(kind: "claude", sessionId: "two", ownerPanelID: second) != nil)
        state.releaseResumeLaunches(ownedBy: first)
        let fresh = state.claimResumeLaunchWithToken(kind: "codex", sessionId: "one", ownerPanelID: second)!
        precondition(!state.releaseResumeLaunch(kind: "codex", sessionId: "one", claim: old))
        precondition(state.claimResumeLaunchWithToken(kind: "claude", sessionId: "two") == nil)
        state.releaseResumeLaunches(ownedBy: first)
        precondition(state.claimResumeLaunchWithToken(kind: "codex", sessionId: "one") == nil)
        precondition(state.releaseResumeLaunch(kind: "codex", sessionId: "one", claim: fresh))
        now = now.addingTimeInterval(61)
        precondition(state.claimResumeLaunchWithToken(kind: "claude", sessionId: "two") != nil)
        print("PASS closed-owner release, duplicate prevention, unrelated-owner isolation, token safety, TTL")
    }
}
'''
source = out / 'Check.swift'
source.write_text(identity + '\n' + guard + '\n' + runner)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source), '-o', str(out / 'check')], check=True)
subprocess.run([str(out / 'check')], check=True)
