import XCTest
@testable import ZedLink

final class WorkspaceModelTests: XCTestCase {
    func testDecodesHostsProjectsAndSkipsDrafts() throws {
        let row: [String: Any] = [
            "host_id": "ssh-1", "kind": "ssh", "label": "hotbot2", "detail": "dev0@hotbot2:2222", "connected": false,
            "projects": [[
                "project_id": "p1", "host_id": "ssh-1", "paths": ["/home/dev0/prj"], "name": "", "open": false,
                "threads": [
                    ["thread_id": "t1", "title": "Fix CI", "agent": "Zed Agent", "updated_at": "2026-11-26T10:00:00Z", "loaded": true] as [String: Any],
                    ["thread_id": NSNull(), "title": "Draft", "agent": "Zed Agent", "updated_at": "2026-11-26T09:00:00Z", "loaded": false] as [String: Any],
                    ["thread_id": "t2", "title": NSNull(), "agent": "Codex", "updated_at": "2026-11-20T09:00:00.123Z", "loaded": false] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any]] as [[String: Any]],
        ]
        let host = try XCTUnwrap(WorkspaceHost(row: row))
        XCTAssertTrue(host.isSSH)
        XCTAssertEqual(host.detail, "dev0@hotbot2:2222")
        let project = try XCTUnwrap(host.projects.first)
        XCTAssertEqual(project.name, "/home/dev0/prj")
        XCTAssertEqual(project.threads.map(\.id), ["t1", "t2"])
        XCTAssertNil(project.threads[1].title)
        XCTAssertNotNil(project.threads[0].updatedAt)
        XCTAssertNotNil(project.threads[1].updatedAt)
        XCTAssertNil(WorkspaceHost(row: ["kind": "local"]))
    }

    func testRecentHistoryIsNewestFirstAcrossProjects() throws {
        func project(_ id: String, _ thread: String, _ date: String) -> [String: Any] {
            ["project_id": id, "paths": ["/p/" + id], "name": id,
             "threads": [["thread_id": thread, "agent": "Zed Agent", "updated_at": date] as [String: Any]] as [[String: Any]]]
        }
        let host = try XCTUnwrap(WorkspaceHost(row: [
            "host_id": "local", "kind": "local",
            "projects": [project("a", "old", "2026-11-20T09:00:00Z"), project("b", "new", "2026-11-26T09:00:00Z")],
        ]))
        let recent = RecentHistoryThread.recent(in: [host])
        XCTAssertEqual(recent.map(\.id), ["new", "old"])
        XCTAssertEqual(recent.first?.project, "b")
    }

    func testHostPathsAndSSHCommands() {
        XCTAssertEqual(HostPath.parent("/home/dev0/prj"), "/home/dev0")
        XCTAssertEqual(HostPath.parent("/home"), "/")
        XCTAssertNil(HostPath.parent("/"))
        XCTAssertEqual(HostPath.parent("C:\\Users\\dev"), "C:\\Users")
        XCTAssertEqual(HostPath.parent("C:\\Users"), "C:\\")
        XCTAssertNil(HostPath.parent("C:\\"))
        XCTAssertEqual(HostPath.child("/", "home"), "/home")
        XCTAssertEqual(HostPath.child("/home/dev0", "prj"), "/home/dev0/prj")
        XCTAssertEqual(HostPath.lastComponent("/home/dev0/prj"), "prj")
        XCTAssertEqual(SSHCommand.normalized("  ssh dev0@hotbot2 -p 2222 "), "ssh dev0@hotbot2 -p 2222")
        XCTAssertEqual(SSHCommand.normalized("dev0@hotbot2"), "ssh dev0@hotbot2")
        XCTAssertEqual(SSHCommand.normalized(" ssh "), "")
    }

    func testWorkspaceFilterMatchesByIdThenHistoryThenName() throws {
        let host = try XCTUnwrap(WorkspaceHost(row: [
            "host_id": "local", "kind": "local", "label": "This computer",
            "projects": [
                ["project_id": "p1", "paths": ["/w/app"], "name": "app", "open": true,
                 "threads": [["thread_id": "t-history", "agent": "Zed Agent"] as [String: Any]] as [[String: Any]]] as [String: Any],
                ["project_id": "p2", "paths": ["/w/docs"], "name": "docs", "open": false] as [String: Any],
            ] as [[String: Any]],
        ]))
        let filter = WorkspaceFilter(hostID: "local", hostLabel: "This computer", projectID: "p1", projectName: "app")
        var byID = NativeThread(id: "a", title: "A", status: "Idle", currentTurnID: nil)
        byID.projectID = "p1"
        var otherID = NativeThread(id: "b", title: "B", status: "Idle", currentTurnID: nil)
        otherID.projectID = "p2"; otherID.project = "app"
        let byHistory = NativeThread(id: "t-history", title: "H", status: "Idle", currentTurnID: nil)
        var byName = NativeThread(id: "c", title: "C", status: "Idle", currentTurnID: nil)
        byName.project = "app"
        var byPaths = NativeThread(id: "d", title: "D", status: "Idle", currentTurnID: nil)
        byPaths.workspacePaths = ["/w/docs"]; byPaths.project = "app"
        var otherHost = NativeThread(id: "e", title: "E", status: "Idle", currentTurnID: nil)
        otherHost.hostID = "ssh-1"; otherHost.projectID = "p1"
        XCTAssertTrue(filter.matches(byID, in: [host]))
        XCTAssertFalse(filter.matches(otherID, in: [host]))
        XCTAssertTrue(filter.matches(byHistory, in: [host]))
        XCTAssertTrue(filter.matches(byName, in: [host]))
        XCTAssertFalse(filter.matches(byPaths, in: [host]))
        XCTAssertFalse(filter.matches(otherHost, in: [host]))
        let hostOnly = WorkspaceFilter(hostID: "local", hostLabel: "This computer")
        XCTAssertTrue(hostOnly.matches(byPaths, in: [host]))
        XCTAssertEqual(filter.narrow([host]).first?.projects.map(\.id), ["p1"])
    }

    func testThreadSettingsDecodeModesAndConfigOptions() throws {
        let modes = try XCTUnwrap(NativeThreadSettings.decodeModes([
            "current": "code",
            "available": [["id": "ask", "name": "Ask"], ["id": "code", "name": "Code", "description": "Edits files"]],
        ] as [String: Any]))
        XCTAssertEqual(modes.currentID, "code")
        XCTAssertEqual(modes.available.map(\.id), ["ask", "code"])
        XCTAssertEqual(modes.available.last?.description, "Edits files")
        XCTAssertNil(NativeThreadSettings.decodeModes(nil))
        let options = NativeThreadSettings.decodeConfigOptions([
            ["id": "effort", "name": "Effort", "current_value": "high",
             "options": [["value": "low", "name": "Low"], ["value": "high", "name": "High"]]] as [String: Any],
            ["id": "empty", "name": "Empty", "options": [] as [[String: Any]]] as [String: Any],
        ] as [[String: Any]])
        XCTAssertEqual(options.map(\.id), ["effort"])
        XCTAssertEqual(options.first?.currentValue, "high")
        XCTAssertEqual(options.first?.options.map(\.value), ["low", "high"])
        XCTAssertTrue(NativeThreadSettings.decodeConfigOptions(nil).isEmpty)
    }

    func testPromptFileNamesAreBareAndBounded() {
        XCTAssertEqual(promptFileName("notes.txt"), "notes.txt")
        XCTAssertEqual(promptFileName(".env"), "env")
        XCTAssertEqual(promptFileName("a/b\\c.md"), "abc.md")
        XCTAssertEqual(promptFileName("..."), "attachment.txt")
        XCTAssertLessThanOrEqual(promptFileName(String(repeating: "x", count: 300) + ".txt").utf8.count, 120)
    }
}
