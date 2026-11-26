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
}
