import XCTest
@testable import ZedLink

@MainActor final class NotificationResponseQueueTests: XCTestCase {
    private func fields(created: String? = "1000") -> [String: String] {
        var data = ["gateway": "gateway", "target": "target", "instance": "instance", "epoch": "epoch",
                    "thread": "thread", "turn": "1", "approval": "approval", "child": ""]
        data["created"] = created
        return data
    }
    func testRelaunchRestoresResponseAndClaimsItOnce() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        queue.enqueue(id: "request", data: fields(), action: "approve")
        queue.enqueue(id: "request", data: fields(), action: "deny")
        let restored = NotificationResponseQueue(defaults: defaults, now: { 1001 })
        XCTAssertEqual(restored.claim()?.action, "approve")
        XCTAssertNil(restored.claim())
        let reopened = NotificationResponseQueue(defaults: defaults, now: { 1002 })
        reopened.enqueue(id: "request", data: fields(), action: "approve")
        XCTAssertNil(reopened.claim())
    }
    func testExpiredFutureAndIncompleteResponsesAreRejected() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 100000 })
        queue.enqueue(id: "expired", data: fields(), action: "approve")
        queue.enqueue(id: "future", data: fields(created: "100001"), action: "approve")
        queue.enqueue(id: "incomplete", data: ["created": "100000"], action: "approve")
        XCTAssertNil(queue.claim())
    }
    func testLegacyAlertsOnlyOpenReviewAndQueueIsBounded() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        for index in 0..<40 { queue.enqueue(id: "request-\(index)", data: fields(created: nil), action: "approve") }
        var count = 0
        while let response = queue.claim() { XCTAssertEqual(response.action, "review"); count += 1 }
        XCTAssertEqual(count, 16)
    }
    func testFailureAlertsAreReviewOnlyAndSurviveRelaunch() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        let data = ["gateway": "gateway", "target": "target", "instance": "instance", "epoch": "epoch",
                    "thread": "thread", "type": "agent_error", "created": "1000"]
        queue.enqueue(id: "failure", data: data, action: "approve")
        let restored = NotificationResponseQueue(defaults: defaults, now: { 1001 })
        let response = try XCTUnwrap(restored.claim())
        XCTAssertEqual(response.action, "review")
        XCTAssertEqual(response.data["thread"], "thread")
        XCTAssertNil(restored.claim())
    }

    func testTurnAndInputAlertsCanOnlyOpenReview() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        for type in ["turn_status", "input_needed", "compaction"] {
            let data = ["gateway": "gateway", "target": "target", "instance": "instance", "epoch": "epoch",
                        "thread": "thread", "type": type, "created": "1000"]
            queue.enqueue(id: type, data: data, action: "approve")
            XCTAssertEqual(queue.claim()?.action, "review")
        }
    }

    func testGatewayPushOpensReviewWithoutTurnOrApproval() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        // The APNs payload's routing fields; `created` arrives as a number and is stringified.
        let data = ["type": "push", "event": "done", "gateway": "gateway", "target": "target", "thread": "thread",
                    "instance": "instance", "epoch": "epoch", "created": "1000", "project_id": "p1", "host_id": "h1"]
        queue.enqueue(id: "push", data: data, action: "com.apple.UNNotificationDefaultActionIdentifier")
        let response = try XCTUnwrap(queue.claim())
        XCTAssertEqual(response.action, "review")
        XCTAssertEqual(response.data["project_id"], "p1")
        // Older gateways send no instance or epoch; the tap still opens the thread.
        queue.enqueue(id: "legacy-push", data: ["type": "push", "gateway": "gateway", "thread": "thread"], action: "approve")
        XCTAssertEqual(queue.claim()?.action, "review")
    }

    func testZedHungAlertNeedsOnlyGatewayAndTargetAndKeepsOnlyRestartAction() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        // The gateway's `zed_hung` payload: no instance, epoch or thread.
        let data = ["type": "zed_hung", "event": "zed_hung", "gateway": "gateway", "target": "target", "created": "1000"]
        queue.enqueue(id: "zed-restart", data: data, action: "restart_zed")
        let restart = try XCTUnwrap(queue.claim())
        XCTAssertEqual(restart.action, "restart_zed")
        XCTAssertEqual(restart.data["target"], "target")
        queue.enqueue(id: "zed-tap", data: data, action: "com.apple.UNNotificationDefaultActionIdentifier")
        XCTAssertEqual(queue.claim()?.action, "review")
        // Approval actions never pass through a Zed alert.
        queue.enqueue(id: "zed-approve", data: data, action: "approve")
        XCTAssertEqual(queue.claim()?.action, "review")
        // A target is required to know which Zed to restart.
        queue.enqueue(id: "zed-no-target", data: ["type": "zed_hung", "gateway": "gateway", "created": "1000"], action: "restart_zed")
        XCTAssertNil(queue.claim())
        // APNs reuses the collapse id for every outage: a replay is dropped, a later outage is not.
        let later = NotificationResponseQueue(defaults: defaults, now: { 2000 })
        later.enqueue(id: "zed-restart", data: data, action: "restart_zed")
        XCTAssertNil(later.claim())
        var nextOutage = data
        nextOutage["created"] = "2000"
        later.enqueue(id: "zed-restart", data: nextOutage, action: "restart_zed")
        XCTAssertEqual(later.claim()?.action, "restart_zed")
    }
}
