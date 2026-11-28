import XCTest
@testable import ZedLink

/// Wave 3 (docs/zlink-wave3-contract.md): mesh address, old profiles, `/auto` interception,
/// autopilot state, statistics parsing and `autopilot` push routing.
final class Wave3Tests: XCTestCase {
    // MARK: §5 mesh

    func testDetectsYggdrasilAddressesAsMesh() {
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[201:abcd::1]:8443"), .mesh)
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[200::1]"), .mesh)
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[3ff:ffff:1::2]:8443"), .mesh)
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[0300:1::1]:8443"), .mesh)
        XCTAssertNil(RouteKind.detect(endpoint: "https://[400::1]:8443"))
        XCTAssertNil(RouteKind.detect(endpoint: "https://[2001:db8::1]:8443"))
        XCTAssertNil(RouteKind.detect(endpoint: "https://[1ff::1]:8443"))
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[fd7a:115c:a1e0::5]:8443"), .tailscale)
        XCTAssertEqual(RouteKind.detect(endpoint: "https://[fd00::5]:8443"), .local)
        XCTAssertEqual(RouteKind.detect(endpoint: "https://192.168.1.4:8443"), .local)
        XCTAssertFalse(RouteKind.isYggdrasil("::1"))
        XCTAssertFalse(RouteKind.isYggdrasil("200.1.2.3"))
    }

    func testDecodesProfileSavedBeforeMeshAddress() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Desktop","route":"Local HTTPS","endpoint":"https://ws.local:8443","gatewayID":"gw-1"}]
        """
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, id)
        XCTAssertNil(profile.meshEndpoint)
        XCTAssertNil(profile.lastWorkingEndpoint)
        XCTAssertEqual(profile.endpoints, ["https://ws.local:8443"])
        XCTAssertEqual(profile.preferredEndpoint, "https://ws.local:8443")
        XCTAssertEqual(profile.routeLabel(for: profile.endpoint), "через локалку")
    }

    func testMeshProfileRoundTripsAndPrefersLastWorkingAddress() throws {
        var profile = ConnectionProfile(name: "Desktop", route: .local, endpoint: "https://ws.local:8443", gatewayID: "gw-1",
                                        meshEndpoint: "https://[201:abcd::1]:8443")
        XCTAssertEqual(profile.endpoints, ["https://ws.local:8443", "https://[201:abcd::1]:8443"])
        XCTAssertEqual(profile.preferredEndpoint, "https://ws.local:8443")
        profile.lastWorkingEndpoint = "https://[201:abcd::1]:8443"
        XCTAssertEqual(profile.preferredEndpoint, "https://[201:abcd::1]:8443")
        XCTAssertEqual(profile.routeLabel(for: profile.preferredEndpoint), "через mesh")
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        // An address the profile no longer has is never used.
        profile.lastWorkingEndpoint = "https://old.example:8443"
        XCTAssertEqual(profile.preferredEndpoint, "https://ws.local:8443")
        profile.meshEndpoint = "  "
        XCTAssertEqual(profile.endpoints, ["https://ws.local:8443"])
    }

    func testOnlyTransportFailuresSwitchAddresses() {
        XCTAssertTrue(GatewayFailure.isTransport(GatewayFailure.native("Gateway request timed out. Check the phone's private route and retry.")))
        XCTAssertTrue(GatewayFailure.isTransport(GatewayFailure.native(GatewayFailure.tlsFailureMessage)))
        XCTAssertTrue(GatewayFailure.isTransport(URLError(.cannotConnectToHost)))
        XCTAssertFalse(GatewayFailure.isTransport(URLError(.cancelled)))
        XCTAssertFalse(GatewayFailure.isTransport(GatewayFailure.changedIdentity))
        XCTAssertFalse(GatewayFailure.isTransport(GatewayFailure.native("UNAUTHENTICATED")))
        XCTAssertFalse(GatewayFailure.isTransport(GatewayFailure.invalidResponse))
    }

    func testOldGatewayAnswersAreUnsupported() {
        XCTAssertTrue(GatewayFailure.isUnsupported(GatewayFailure.native("UNSUPPORTED_CAPABILITY")))
        XCTAssertTrue(GatewayFailure.isUnsupported(GatewayFailure.native("HTTP 403")))
        XCTAssertFalse(GatewayFailure.isUnsupported(GatewayFailure.native("INVALID_REQUEST")))
        XCTAssertTrue(GatewayFailure.native("PROJECT_NOT_OPEN").isProjectNotOpen)
        XCTAssertFalse(GatewayFailure.native("THREAD_NOT_LOADED").isProjectNotOpen)
    }

    // MARK: §3 `/auto`

    func testInterceptedAutoCommandIsANoteNotASend() {
        let intercepted: [String: Any] = ["intercepted": "autopilot", "message": "Автопродолжение включено для этого треда"]
        XCTAssertEqual(AutopilotInterception.message(in: intercepted), "Автопродолжение включено для этого треда")
        XCTAssertEqual(AutopilotInterception.message(in: ["intercepted": "autopilot"]), "Команда автопилота выполнена.")
        XCTAssertNil(AutopilotInterception.message(in: ["outcome": "received"]))
        XCTAssertNil(AutopilotInterception.message(in: ["intercepted": "other", "message": "x"]))
    }

    // MARK: §3, §6.1, §6.2 autopilot state

    func testThreadsWithoutRecordAreOnAndStripStatus() {
        let now = Date().timeIntervalSince1970
        let settings: [String: Any] = ["enabled": true, "stop_percent": 98, "hold_percent": 95]
        let threads: [[String: Any]] = [["target_id": "t", "thread_id": "off", "auto_continue": false, "actions_today": 2]]
        let jobs: [[String: Any]] = [["job_id": "j1", "target_id": "t", "thread_id": "held", "kind": "continue",
                                      "at": now + 3600, "reason": "budget_hold", "attempts": 0]]
        let log: [[String: Any]] = [["at": now - 60, "target_id": "t", "thread_id": "held", "action": "continued", "detail": "ok"]]
        let status = AutopilotStatus(["settings": settings, "threads": threads, "jobs": jobs, "log": log])
        XCTAssertTrue(status.settings.hasEnabled)
        XCTAssertTrue(status.settings.hasStopPercent)
        XCTAssertEqual(status.summary(targetID: "t", threadID: "new").statusText, "Автопилот: вкл")
        XCTAssertTrue(status.summary(targetID: "t", threadID: "new").active)
        XCTAssertEqual(status.summary(targetID: "t", threadID: "off").statusText, "Автопилот: выкл")
        XCTAssertTrue(status.summary(targetID: "t", threadID: "held").statusText.hasPrefix("Автопилот: ждёт сброса до "))
        XCTAssertEqual(status.log.count, 1)

        var disabled = status
        disabled.settings.enabled = false
        XCTAssertFalse(disabled.summary(targetID: "t", threadID: "new").active)
    }

    func testSettingsSendOnlyChangedAndKnownFields() {
        let old = AutopilotSettings(["continue_text": "продолжай", "daily_limit": 5, "hold_percent": 95])
        XCTAssertFalse(old.hasEnabled)
        var edited = old
        edited.dailyLimit = 7
        edited.enabled = false
        let changes = edited.changes(from: old)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes["daily_limit"] as? Int, 7)
        XCTAssertNil(changes["enabled"])
        XCTAssertNil(changes["stop_percent"])
        XCTAssertTrue(old.changes(from: old).isEmpty)
    }

    func testAutopilotNotes() throws {
        let stop = try XCTUnwrap(AutopilotLogEntry(["at": 1_800_000_000, "action": "stopped", "detail": "used 98.4"], index: 0))
        XCTAssertEqual(stop.note(stopPercent: 98), "Автопилот: остановил на 98 %")
        let resumed = try XCTUnwrap(AutopilotLogEntry(["at": 1_800_000_100, "action": "continued", "reason": "rate_limit"], index: 1))
        XCTAssertEqual(resumed.note(stopPercent: 98), "Автопилот: продолжил после сброса лимита")
        XCTAssertNil(AutopilotLogEntry(["action": "continued"], index: 2))
    }

    // MARK: §6.5, §6.6 statistics

    func testTokenCountsAcceptBridgeAndColumnNames() {
        let bridge = TokenCounts(["input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 100, "cache_write_tokens": 20, "thought_tokens": 3])
        XCTAssertEqual(bridge.total, 135)
        XCTAssertEqual(bridge.thought, 3)
        let nestedTokens: [String: Int] = ["input": 1, "output": 2, "cache_read": 3, "cache_write": 4]
        let columns = TokenCounts(["tokens": nestedTokens])
        XCTAssertEqual(columns.total, 10)
        XCTAssertEqual(TokenCounts(["input": 1, "total": 99]).total, 99)
        let totals: [String: Int] = ["input_tokens": 1, "output_tokens": 2, "turns": 4]
        let stats = ThreadTokenStats(["totals": totals, "compactions": 1])
        XCTAssertEqual(stats.turns, 4)
        XCTAssertEqual(stats.compactions, 1)
    }

    func testUsageStatsParseFlatAndNestedDays() {
        let days: [[String: Any]] = [
            ["day": "2026-11-27", "agent": "claude", "input": 10, "output": 1, "turns": 2],
            ["day": "2026-11-27", "agent": "codex", "input": 5, "turns": 1],
            ["day": "2026-11-28", "agent": "claude", "input": 7, "turns": 1],
        ]
        let top: [[String: Any]] = [["target_id": "t", "thread_id": "a", "input": 3], ["target_id": "t", "thread_id": "b", "input": 9]]
        let flat = UsageStats(["days": days, "threads": top])
        XCTAssertEqual(flat.days.count, 3)
        XCTAssertEqual(flat.agents, ["claude", "codex"])
        XCTAssertEqual(flat.totals(agent: "claude").tokens.total, 18)
        XCTAssertEqual(flat.totals(agent: "claude").turns, 3)
        XCTAssertEqual(flat.threads.first?.threadID, "b")
        let agents: [[String: Any]] = [["agent": "claude", "input": 4], ["agent": "codex", "output": 2]]
        let nestedDays: [[String: Any]] = [["day": "2026-11-27", "agents": agents]]
        let nested = UsageStats(["days": nestedDays])
        XCTAssertEqual(nested.days.count, 2)
        let rows: [[String: Any]] = [["kind": "five_hour", "at": 20, "used_percent": 50], ["kind": "five_hour", "at": 10, "used_percent": 140]]
        let samples = LimitSample.list(["samples": rows])
        XCTAssertEqual(samples.map(\.usedPercent), [100, 50])
    }

    // MARK: Push routing

    @MainActor func testAutopilotPushOpensItsThread() throws {
        let suite = "notification-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = NotificationResponseQueue(defaults: defaults, now: { 1000 })
        let data = ["type": "push", "event": "autopilot", "gateway": "gateway", "target": "target", "thread": "thread", "created": "999"]
        queue.enqueue(id: "thread:autopilot", data: data, action: "approve")
        let response = try XCTUnwrap(queue.claim())
        XCTAssertEqual(response.action, "review")
        XCTAssertEqual(response.data["event"], "autopilot")
        // A later autopilot push of the same thread reuses the collapse id but is a new alert.
        queue.enqueue(id: "thread:autopilot", data: data.merging(["created": "1000"]) { _, new in new }, action: "review")
        XCTAssertNotNil(queue.claim())
    }
}
