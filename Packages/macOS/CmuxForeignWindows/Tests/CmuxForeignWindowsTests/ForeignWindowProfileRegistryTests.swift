import CoreGraphics
import Foundation
import Testing

@testable import CmuxForeignWindows

@MainActor
private final class FakeForeignWindowSession: ForeignWindowProfileSession {
    struct Presentation: Equatable {
        let targetFrame: CGRect?
        let isVisible: Bool
        let isFocused: Bool
        let raiseWindow: Bool
    }

    let profile: String
    private(set) var presentations: [Presentation] = []
    private(set) var invalidateCount = 0

    init(profile: String) {
        self.profile = profile
    }

    var isRunning: Bool { invalidateCount == 0 && !presentations.isEmpty }

    var processIdentifier: pid_t? { isRunning ? 4242 : nil }

    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    ) {
        presentations.append(
            Presentation(
                targetFrame: targetFrame,
                isVisible: isVisible,
                isFocused: isFocused,
                raiseWindow: raiseWindow
            )
        )
    }

    func invalidate() {
        invalidateCount += 1
    }
}

@MainActor
private final class FakeForeignWindowHost: ForeignWindowProfileHost {
    private(set) var isPresenting = false

    func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool) {
        self.isPresenting = isPresenting
    }
}

@MainActor
private final class RegistryHarness {
    private(set) var created: [FakeForeignWindowSession] = []
    private(set) var registry: ForeignWindowProfileRegistry!

    init() {
        registry = ForeignWindowProfileRegistry(
            observesApplicationTermination: false
        ) { [unowned self] profile in
            let session = FakeForeignWindowSession(profile: profile)
            self.created.append(session)
            return session
        }
    }
}

@Suite
@MainActor
struct ForeignWindowProfileRegistryTests {
    private let frameA = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let frameB = CGRect(x: 400, y: 0, width: 400, height: 300)

    @Test
    func testLeaseBookPrefersFocusedThenMostRecentlyShownHost() {
        var book = ForeignWindowLeaseBook()
        let panelA = UUID()
        let panelB = UUID()
        let hostA = UUID()
        let hostB = UUID()
        book.claim(profile: "work", panelID: panelA)
        book.claim(profile: "work", panelID: panelB)
        book.attach(hostID: hostA, panelID: panelA, profile: "work")
        book.attach(hostID: hostB, panelID: panelB, profile: "work")

        #expect(book.presenter(for: "work") == nil)

        book.update(hostID: hostA, isVisible: true, isFocused: false, targetFrame: frameA)
        book.update(hostID: hostB, isVisible: true, isFocused: false, targetFrame: frameB)
        #expect(book.presenter(for: "work") == hostB)

        book.update(hostID: hostA, isVisible: true, isFocused: true, targetFrame: frameA)
        #expect(book.presenter(for: "work") == hostA)

        book.update(hostID: hostA, isVisible: false, isFocused: false, targetFrame: nil)
        #expect(book.presenter(for: "work") == hostB)
    }

    @Test
    func testLeaseBookIgnoresHostsWhosePanelReleasedTheProfile() {
        var book = ForeignWindowLeaseBook()
        let panelA = UUID()
        let panelB = UUID()
        let hostA = UUID()
        book.claim(profile: "work", panelID: panelA)
        book.claim(profile: "work", panelID: panelB)
        book.attach(hostID: hostA, panelID: panelA, profile: "work")
        book.update(hostID: hostA, isVisible: true, isFocused: true, targetFrame: frameA)

        #expect(book.release(panelID: panelA) == nil)
        #expect(book.presenter(for: "work") == nil)
        #expect(book.release(panelID: panelB) == "work")
        #expect(!book.isClaimed("work"))
    }

    @Test
    func testProcessIdentifierFollowsTheProfileSession() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panel = UUID()
        let hostID = UUID()
        let host = FakeForeignWindowHost()
        registry.claim(profile: "work", panelID: panel)
        #expect(registry.processIdentifier(forProfile: "work") == nil)

        registry.attach(host: host, hostID: hostID, panelID: panel, profile: "work")
        registry.updateHost(
            hostID: hostID,
            isVisible: true,
            isFocused: true,
            targetFrame: frameA,
            raiseWindow: false
        )
        #expect(registry.processIdentifier(forProfile: "work") == 4242)
        #expect(registry.processIdentifier(forProfile: "personal") == nil)

        registry.releasePanel(panel)
        #expect(registry.processIdentifier(forProfile: "work") == nil)
    }

    @Test
    func testTwoPanesWithSameProfileShareOneSession() throws {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let hostA = FakeForeignWindowHost()
        let hostB = FakeForeignWindowHost()
        let hostAID = UUID()
        let hostBID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "work", panelID: panelB)
        #expect(harness.created.isEmpty)

        registry.attach(host: hostA, hostID: hostAID, panelID: panelA, profile: "work")
        registry.attach(host: hostB, hostID: hostBID, panelID: panelB, profile: "work")
        #expect(harness.created.isEmpty)

        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: false, targetFrame: frameB, raiseWindow: false)

        #expect(harness.created.count == 1)
        #expect(hostA.isPresenting)
        #expect(!hostB.isPresenting)
        #expect(harness.created.first?.presentations.last?.targetFrame == frameA)

        // Focus moves to B: B takes the window, A shows its placeholder. The
        // handoff itself raises the window; B's later focus update does not
        // need to (the real host passes its own raise on becoming focused).
        let session = try #require(harness.created.first)
        let beforeHandoff = session.presentations.count
        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: false, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: false)
        #expect(harness.created.count == 1)
        #expect(!hostA.isPresenting)
        #expect(hostB.isPresenting)
        let handoff = Array(session.presentations[beforeHandoff...])
        #expect(handoff.first?.targetFrame == frameB)
        #expect(handoff.first?.raiseWindow == true)
        #expect(handoff.last?.targetFrame == frameB)
        #expect(handoff.last?.isFocused == true)
    }

    @Test
    func testViewTeardownDetachesWithoutTerminating() throws {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panel = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panel)
        registry.attach(host: host, hostID: hostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        let session = try #require(harness.created.first)

        registry.detach(hostID: hostID)
        #expect(session.invalidateCount == 0)
        #expect(session.presentations.last?.isVisible == false)

        // The pane re-mounts elsewhere (split move): same session, new host.
        let movedHost = FakeForeignWindowHost()
        let movedHostID = UUID()
        registry.attach(host: movedHost, hostID: movedHostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: movedHostID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: false)
        #expect(harness.created.count == 1)
        #expect(movedHost.isPresenting)
        #expect(session.presentations.last?.targetFrame == frameB)
    }

    @Test
    func testClosingLastPanelTerminatesButSharedProfileSurvives() throws {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "work", panelID: panelB)
        registry.attach(host: host, hostID: hostID, panelID: panelA, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        let session = try #require(harness.created.first)

        registry.releasePanel(panelA)
        #expect(session.invalidateCount == 0)
        #expect(!host.isPresenting)
        #expect(registry.claimedProfiles == ["work"])

        registry.releasePanel(panelB)
        #expect(session.invalidateCount == 1)
        #expect(registry.sessionProfiles == [])
        #expect(registry.claimedProfiles == [])
    }

    @Test
    func testDifferentProfilesGetSeparateSessions() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let hostA = FakeForeignWindowHost()
        let hostB = FakeForeignWindowHost()
        let hostAID = UUID()
        let hostBID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "personal", panelID: panelB)
        registry.attach(host: hostA, hostID: hostAID, panelID: panelA, profile: "work")
        registry.attach(host: hostB, hostID: hostBID, panelID: panelB, profile: "personal")
        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: false, targetFrame: frameB, raiseWindow: false)

        #expect(harness.created.map(\.profile).sorted() == ["personal", "work"])
        #expect(hostA.isPresenting)
        #expect(hostB.isPresenting)
    }

    @Test
    func testTerminateAllInvalidatesAndBlocksRelaunch() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panel = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panel)
        registry.attach(host: host, hostID: hostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)

        registry.terminateAll()
        #expect(harness.created.map(\.invalidateCount) == [1])

        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: true)
        #expect(harness.created.count == 1)
    }
}
