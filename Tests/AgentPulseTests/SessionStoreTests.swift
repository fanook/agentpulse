import XCTest
@testable import AgentPulse

@MainActor
final class SessionStoreTests: XCTestCase {
    func testSessionLifecycle() {
        let store = SessionStore()
        // Start with a clean slate.
        for s in store.sessions { store.remove(id: s.id) }

        let start = HookEvent(event: "SessionStart", sessionId: "s1", cwd: "/tmp/proj",
                              transcriptPath: nil, notificationType: nil,
                              exitReason: nil, terminal: nil)
        store.apply(start)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, .idle)

        let permNotif = HookEvent(event: "Notification", sessionId: "s1", cwd: "/tmp/proj",
                                  transcriptPath: nil, notificationType: "permission_prompt",
                                  exitReason: nil, terminal: nil)
        store.apply(permNotif)
        XCTAssertEqual(store.sessions[0].status, .waiting)
        XCTAssertEqual(store.waitingCount, 1)

        let stop = HookEvent(event: "Stop", sessionId: "s1", cwd: nil,
                             transcriptPath: nil, notificationType: nil,
                             exitReason: nil, terminal: nil)
        store.apply(stop)
        // After Stop the permission has been resolved — back to idle.
        XCTAssertEqual(store.sessions[0].status, .idle)
        XCTAssertEqual(store.waitingCount, 0)
        XCTAssertNil(store.sessions[0].lastNotification)

        let end = HookEvent(event: "SessionEnd", sessionId: "s1", cwd: nil,
                            transcriptPath: nil, notificationType: nil,
                            exitReason: "logout", terminal: nil)
        store.apply(end)
        XCTAssertNil(store.sessions.first(where: { $0.id == "s1" }))
    }

    func testStopWithoutWaitingGoesIdle() {
        let store = SessionStore()
        for s in store.sessions { store.remove(id: s.id) }

        store.apply(HookEvent(event: "SessionStart", sessionId: "s2", cwd: "/tmp",
                              transcriptPath: nil, notificationType: nil,
                              exitReason: nil, terminal: nil))
        store.apply(HookEvent(event: "Stop", sessionId: "s2", cwd: nil,
                              transcriptPath: nil, notificationType: nil,
                              exitReason: nil, terminal: nil))
        XCTAssertEqual(store.sessions.first(where: { $0.id == "s2" })?.status, .idle)
        store.remove(id: "s2")
    }
}
