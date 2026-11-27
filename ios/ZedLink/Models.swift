import Foundation

enum RouteKind: String, CaseIterable, Codable, Identifiable {
    case tailscale = "Tailscale"
    case wireGuard = "WireGuard"
    case otherVPN = "Other VPN"
    case local = "Local HTTPS"
    case custom = "Custom HTTPS"

    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .tailscale: "Connect your existing Tailscale app, then enter the workstation's verified HTTPS hostname."
        case .wireGuard: "Connect your existing WireGuard tunnel and enter a hostname routed to the workstation."
        case .otherVPN: "Connect a VPN that routes to the workstation, then enter its HTTPS address."
        case .local: "Join the same trusted local network and use a certificate valid for the entered hostname."
        case .custom: "Enter the HTTPS address of a trusted reverse proxy that forwards ZedLink API requests."
        }
    }
}

struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var route: RouteKind
    var endpoint: String
    var gatewayID: String
}

struct ZedTarget: Identifiable, Equatable {
    let id: String
    let label: String
    let available: Bool
}

struct AgentOption: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
}

struct NativeAgentActivity: Equatable {
    let phase: String
    let label: String
    let detail: String?

    static let ready = NativeAgentActivity(phase: "idle", label: "Ready", detail: nil)

    init(phase: String, label: String, detail: String?) {
        self.phase = phase
        self.label = label
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail : nil
    }

    init(_ value: Any?, status: String, currentTurnID: Int?) {
        let row = value as? [String: Any]
        let fallbackWorking = currentTurnID != nil || status == "Generating"
        phase = row?["phase"] as? String ?? (fallbackWorking ? "responding" : "idle")
        label = row?["label"] as? String ?? (fallbackWorking ? "Agent is responding" : "Ready")
        let rawDetail = row?["detail"] as? String
        detail = rawDetail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawDetail : nil
    }

    var isWorking: Bool { phase != "idle" }
    var isCompacting: Bool { phase == "compacting" }
    var isWaitingForApproval: Bool { phase == "waiting_for_approval" }
    var displayText: String { detail.map { "\(label) · \($0)" } ?? label }
}

struct NativeThread: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let currentTurnID: Int?
    var agentName = "Zed Agent"
    var retrying = false
    var failed = false
    var approvalCount: Int? = nil
    var inputCount: Int? = nil
    var activity = NativeAgentActivity.ready
    /// Display name of the Zed project that owns this thread, when desktop Zed reports one.
    var project: String? = nil
    /// Agent id from `thread.list` (`agent.id`), used to start a sibling session with the same agent.
    var agentID: String? = nil
    /// Workspace identity reported by newer bridges; older bridges omit these.
    var hostID: String? = nil
    var projectID: String? = nil
    var workspacePaths: [String] = []

    var searchText: String { [title, agentName, id, project ?? ""].joined(separator: " ") }
}

struct NativeCommand: Identifiable, Equatable {
    let name: String
    let description: String
    let category: String
    let requiresArgument: Bool
    var inputHint: String? = nil
    var execution = "prompt"
    var confirmation: String? = nil
    var warning: String? = nil

    var id: String { name }
}

struct NativeApproval: Identifiable, Equatable {
    let id: String
    let turnID: Int?
    let toolName: String
    let display: String
    let rawInput: String?
    let detailsTruncated: Bool
    let canApproveOnce: Bool
    let canDenyOnce: Bool
    let subagentID: String?
    let authorizationKind: String
    let decisions: [NativeApprovalDecision]
    var viewIdentity: String { "\(subagentID ?? "root"):\(turnID ?? -1):\(id)" }
}

struct NativeApprovalDecision: Identifiable, Equatable {
    let optionID: String
    let label: String
    let optionKind: String
    let choiceIndex: Int?
    let selectedPatternIndices: [Int]
    let action: String?

    var id: String {
        "\(optionID):\(choiceIndex.map(String.init) ?? "flat"):\(selectedPatternIndices.map(String.init).joined(separator: ","))"
    }

    var isRejecting: Bool { optionKind.hasPrefix("reject") }
    var displayLabel: String {
        guard let action else { return label }
        return "\(action == "allow" ? "Allow" : "Deny") · \(label)"
    }
}

struct NativeElicitationField: Identifiable, Equatable {
    let id: String
    let title: String
    let type: String
    let required: Bool
    let choices: [String]
    var defaultValue: String? = nil
    var minimum: Double? = nil
    var maximum: Double? = nil
    var minLength: Int? = nil
    var maxLength: Int? = nil
}

struct NativeElicitation: Identifiable, Equatable {
    let id: String
    let message: String
    let url: String?
    let fields: [NativeElicitationField]
}

struct NativeEntryMeta: Equatable {
    let kind: String
    let callID: String?
    let elicitationID: String?

    static func page(_ raw: Any?, count: Int) -> [NativeEntryMeta?] {
        guard let rows = raw as? [[String: Any]], rows.count == count else {
            return Array(repeating: nil, count: count)
        }
        return rows.map { row in
            NativeEntryMeta(kind: row["kind"] as? String ?? "other",
                            callID: row["call_id"] as? String,
                            elicitationID: row["elicitation_id"] as? String)
        }
    }
}

struct NativeQueueEntry: Identifiable, Equatable {
    let id: Int
    let preview: String
    let steer: Bool
}

struct NativeEditReview: Equatable {
    let changedFiles: Int
    let linesAdded: Int
    let linesRemoved: Int
}

struct NativeModelOption: Identifiable, Equatable {
    let id: String
    let providerID: String
    let name: String
}

struct NativeAgentProfile: Identifiable, Equatable { let id: String; let name: String }

struct NativeThreadSettings: Equatable {
    let modelID: String?
    let providerID: String?
    let models: [NativeModelOption]
    let usedTokens: Int?
    let maxTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let remainingTokens: Int?
    var profileID: String? = nil
    var profiles: [NativeAgentProfile] = []
    var thinkingEnabled: Bool? = nil
    var thinkingSupported = false
    var thinkingCanDisable = false
    /// `false` when the agent (for example an external ACP agent) owns its configuration.
    var editable: Bool? = nil
    var configurationOwner: String? = nil
    var modes: NativeSessionModes? = nil
    var configOptions: [NativeConfigOption] = []

    var managedByAgent: Bool { editable == false }
    /// Model choices can still be offered for an external agent that advertises them.
    var canSelectModels: Bool { editable != false || models.contains(where: { $0.providerID == "acp" }) }
}

struct NativeSessionMode: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

struct NativeSessionModes: Equatable {
    let currentID: String?
    let available: [NativeSessionMode]
}

struct NativeConfigChoice: Identifiable, Equatable {
    let value: String
    let name: String
    var id: String { value }
}

struct NativeConfigOption: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let currentValue: String?
    let options: [NativeConfigChoice]
}

extension NativeThreadSettings {
    /// Loosely typed scalar (string, number or bool) as the string the update call sends back.
    static func scalarText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `modes: {current, available: [{id, name, description}]}`; optional so old bridges still decode.
    static func decodeModes(_ value: Any?) -> NativeSessionModes? {
        guard let row = value as? [String: Any] else { return nil }
        let rows: [[String: Any]] = row["available"] as? [[String: Any]] ?? row["available_modes"] as? [[String: Any]] ?? []
        let available: [NativeSessionMode] = rows.compactMap { item -> NativeSessionMode? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name: String = item["name"] as? String ?? id
            let detail: String? = (item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return NativeSessionMode(id: id, name: name.isEmpty ? id : name, description: detail)
        }
        guard !available.isEmpty else { return nil }
        let current: String? = scalarText(row["current"]) ?? scalarText(row["current_mode_id"])
        return NativeSessionModes(currentID: current, available: available)
    }

    /// `config_options: [{id, name, description, current_value, options: [{value, name}]}]`.
    static func decodeConfigOptions(_ value: Any?) -> [NativeConfigOption] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> NativeConfigOption? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let choiceRows: [[String: Any]] = row["options"] as? [[String: Any]] ?? []
            let choices: [NativeConfigChoice] = choiceRows.compactMap { item -> NativeConfigChoice? in
                guard let value = scalarText(item["value"]) else { return nil }
                let name: String = item["name"] as? String ?? value
                return NativeConfigChoice(value: value, name: name.isEmpty ? value : name)
            }
            guard !choices.isEmpty else { return nil }
            let name: String = row["name"] as? String ?? id
            let detail: String? = (row["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return NativeConfigOption(id: id, name: name.isEmpty ? id : name, description: detail,
                                      currentValue: scalarText(row["current_value"]), options: choices)
        }
    }
}

struct NativeRewindPoint: Identifiable, Equatable {
    let id: String
    let entryIndex: Int
    let entriesRemoved: Int
}

struct NativeSubagent: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let currentTurnID: Int?
    let entries: [String]
    var entryStartIndex = 0
    var totalEntries = 0
    var entriesTruncated = false
    var isActive: Bool { currentTurnID != nil || ["pending", "running", "inprogress", "in progress", "waiting", "generating"].contains(status.lowercased()) }
}
struct NativeProjectFile: Identifiable, Equatable { let id: String; let kind: String; let size: Int? }
struct NativeChange: Identifiable, Equatable { let id: String; let status: String; let staging: String }
struct NativeTerminal: Identifiable, Equatable {
    let id: String
    let title: String
    let workingDirectory: String?
    let taskLabel: String?
    let taskState: String?
}
struct NativeTerminalRun: Equatable {
    let text: String
    let foreground: String
    let background: String
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let dim: Bool
}
struct NativeTerminalSnapshot: Equatable {
    let terminal: NativeTerminal
    let content: String
    let truncated: Bool
    var styledRuns: [NativeTerminalRun] = []
}
struct NativeConfiguredTask: Identifiable, Equatable {
    let id: String
    let label: String
    let source: String
}
struct NativeDebugScenario: Identifiable, Equatable {
    let id: String
    let label: String
    let adapter: String
    let source: String
}
struct NativeDebuggerThread: Identifiable, Equatable {
    let id: Int
    let name: String
    let status: String
}
struct NativeDebuggerSession: Identifiable, Equatable {
    let id: String
    let label: String
    let adapter: String
    let terminated: Bool
    let canRestart: Bool
    let canStepBack: Bool
    let threads: [NativeDebuggerThread]
}

/// Authoritative native failure, separate from gateway connectivity and send delivery.
struct NativeAgentError: Equatable {
    let kind: String
    let title: String
    let message: String
    let retrying: Bool

    init?(snapshot: [String: Any]) {
        if let error = snapshot["agent_error"] as? [String: Any],
           let title = error["title"] as? String, let message = error["message"] as? String {
            kind = error["kind"] as? String ?? "agent_error"
            self.title = title; self.message = message
            retrying = error["retrying"] as? Bool ?? false
        } else if snapshot["had_error"] as? Bool == true {
            kind = "agent_error"; title = "Agent request failed"
            message = "The last native Zed Agent turn failed. Open desktop Zed for additional details."
            retrying = false
        } else { return nil }
    }
}

struct ThreadSnapshot: Equatable {
    let threadID: String
    let title: String
    let status: String
    let currentTurnID: Int?
    let instanceID: String
    let epoch: String
    let lastSequence: Int
    let entries: [String]
    let entryStartIndex: Int
    let totalEntries: Int
    let hasOlderEntries: Bool
    let activityEntries: [String]
    let truncated: Bool
    let activityTruncated: Bool
    let pendingApprovals: [NativeApproval]
    let rewindPoints: [NativeRewindPoint]
    let subagents: [NativeSubagent]
    var agentError: NativeAgentError? = nil
    var entryMeta: [NativeEntryMeta?] = []

    var isBusy: Bool { status == "Generating" || currentTurnID != nil }
}

struct PendingSend: Codable {
    var localConfirmed: Bool? = nil
    let id: String
    let instanceID: String
    let epoch: String
    let threadID: String
    // A draft remains in memory only. A relaunched app reconciles by ID without resending.
    var text: String?
    var contextPaths: [String] = []
    var attachments: [PromptAttachment] = []

    var submissionParams: [String: Any] {
        var params: [String: Any] = ["instance_id": instanceID, "epoch": epoch, "thread_id": threadID, "text": text ?? ""]
        if localConfirmed == true { params["local_confirmed"] = true }
        if !contextPaths.isEmpty { params["context_paths"] = contextPaths }
        if !attachments.isEmpty { params["uploads"] = attachments.map(\.payload) }
        return params
    }

    enum CodingKeys: String, CodingKey { case id, instanceID, epoch, threadID }
}

enum LinkState: Equatable {
    case offline
    case connecting
    case live
    case reconnecting
    case stale

    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Stale"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .live: "circle.fill"
        case .reconnecting: "arrow.clockwise"
        case .stale: "exclamationmark.triangle"
        }
    }
}

struct PromptAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var payload: [String: Any] { ["name": name, "mime_type": mimeType, "data": data.base64EncodedString()] }
}

struct ProjectSearchMatch: Identifiable {
    let path: String
    let line: Int
    let column: Int
    let preview: String
    var id: String { "\(path):\(line):\(column)" }
}

enum WorkspacePage: String { case files, changes, terminal, debug, activity }

// MARK: Workspaces (hosts, projects and thread history reported by desktop Zed)

struct WorkspaceHistoryThread: Identifiable, Equatable {
    let id: String
    let title: String?
    let agent: String
    let updatedAt: Date?
    let loaded: Bool
}

struct WorkspaceProject: Identifiable, Equatable {
    let id: String
    let hostID: String
    let paths: [String]
    let name: String
    let open: Bool
    let threads: [WorkspaceHistoryThread]
}

struct WorkspaceHost: Identifiable, Equatable {
    let id: String
    let kind: String
    let label: String
    let detail: String?
    let connected: Bool
    let projects: [WorkspaceProject]

    var isSSH: Bool { kind == "ssh" }
}

/// The breadcrumb selection: a host, optionally narrowed to one of its workspaces.
/// Labels are kept so the crumb reads correctly before `workspace.list` returns.
struct WorkspaceFilter: Codable, Equatable {
    let hostID: String
    let hostLabel: String
    var projectID: String? = nil
    var projectName: String? = nil

    var label: String {
        guard let projectName else { return hostLabel }
        return hostLabel + " › " + projectName
    }

    /// True when `thread` belongs to this host/workspace. Prefers the bridge's `project_id`,
    /// then `workspace_paths`, then the workspace's history thread ids, then the project name.
    func matches(_ thread: NativeThread, in hosts: [WorkspaceHost]) -> Bool {
        if let threadHost = thread.hostID, threadHost != hostID { return false }
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            // Without workspace.list only the bridge's own ids can be compared.
            if let projectID, let threadProject = thread.projectID { return threadProject == projectID }
            if projectID == nil, thread.hostID != nil { return true }
            return hosts.isEmpty
        }
        if let projectID {
            if let threadProject = thread.projectID { return threadProject == projectID }
            guard let project = host.projects.first(where: { $0.id == projectID }) else { return false }
            return Self.thread(thread, belongsTo: project)
        }
        if thread.hostID == hostID { return true }
        if let threadProject = thread.projectID { return host.projects.contains(where: { $0.id == threadProject }) }
        return host.projects.contains(where: { Self.thread(thread, belongsTo: $0) })
    }

    static func thread(_ thread: NativeThread, belongsTo project: WorkspaceProject) -> Bool {
        if !thread.workspacePaths.isEmpty { return Set(thread.workspacePaths) == Set(project.paths) }
        if project.threads.contains(where: { $0.id == thread.id }) { return true }
        guard let name = thread.project else { return false }
        return name == project.name || project.paths.contains(where: { HostPath.lastComponent($0) == name })
    }

    /// Narrows `hosts` to the selected host and workspace (used for the "Recent in Zed" list).
    func narrow(_ hosts: [WorkspaceHost]) -> [WorkspaceHost] {
        hosts.filter { $0.id == hostID }.map { host in
            guard let projectID else { return host }
            let projects: [WorkspaceProject] = host.projects.filter { $0.id == projectID }
            return WorkspaceHost(id: host.id, kind: host.kind, label: host.label, detail: host.detail,
                                 connected: host.connected, projects: projects)
        }
    }
}

/// A host/workspace pair a new session is created in.
struct WorkspaceLocation: Identifiable, Equatable {
    let host: WorkspaceHost
    let project: WorkspaceProject
    var id: String { host.id + "\n" + project.id }
}

/// A history thread with the project it belongs to, for the "Recent in Zed" list.
struct RecentHistoryThread: Identifiable, Equatable {
    let thread: WorkspaceHistoryThread
    let project: String
    let host: String?

    var id: String { thread.id }
    var searchText: String { [thread.title ?? "", thread.agent, project, host ?? ""].joined(separator: " ") }
    var meta: String {
        var parts: [String] = [project]
        if let host { parts.append(host) }
        parts.append(thread.agent)
        if let date = thread.updatedAt { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    /// Newest first, across every host and project.
    static func recent(in hosts: [WorkspaceHost]) -> [RecentHistoryThread] {
        var rows: [RecentHistoryThread] = []
        for host in hosts {
            for project in host.projects {
                for thread in project.threads {
                    rows.append(RecentHistoryThread(thread: thread, project: project.name, host: host.isSSH ? host.label : nil))
                }
            }
        }
        return rows.sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
    }
}

extension WorkspaceHistoryThread {
    /// Never-sent drafts have no ACP session id; they cannot be opened remotely and are skipped.
    init?(row: [String: Any]) {
        guard let id = row["thread_id"] as? String, !id.isEmpty else { return nil }
        let title: String? = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, title: title, agent: row["agent"] as? String ?? "Agent",
                  updatedAt: WorkspaceHistoryThread.date(row["updated_at"] as? String),
                  loaded: row["loaded"] as? Bool ?? false)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension WorkspaceProject {
    init?(row: [String: Any], hostID: String) {
        guard let id = row["project_id"] as? String, let rawPaths = row["paths"] as? [String] else { return nil }
        let paths: [String] = rawPaths.filter { !$0.isEmpty }
        let rawName: String = row["name"] as? String ?? ""
        let name: String = rawName.isEmpty ? (paths.first ?? "Untitled project") : rawName
        let rows: [[String: Any]] = row["threads"] as? [[String: Any]] ?? []
        let threads: [WorkspaceHistoryThread] = rows.compactMap { WorkspaceHistoryThread(row: $0) }
        self.init(id: id, hostID: hostID, paths: paths, name: name, open: row["open"] as? Bool ?? false, threads: threads)
    }
}

extension WorkspaceHost {
    init?(row: [String: Any]) {
        guard let id = row["host_id"] as? String, !id.isEmpty else { return nil }
        let rows: [[String: Any]] = row["projects"] as? [[String: Any]] ?? []
        let projects: [WorkspaceProject] = rows.compactMap { WorkspaceProject(row: $0, hostID: id) }
        let label: String = row["label"] as? String ?? id
        let detail: String? = (row["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, kind: row["kind"] as? String == "ssh" ? "ssh" : "local", label: label.isEmpty ? id : label,
                  detail: detail, connected: row["connected"] as? Bool ?? false, projects: projects)
    }
}

struct HostDirectoryEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
    var id: String { name }
}

struct HostDirectoryListing: Equatable {
    let path: String
    let entries: [HostDirectoryEntry]
}

/// One `host.directory` poll result. Callers repeat the request until `.ready`.
enum HostDirectoryState: Equatable {
    case connecting
    case loading
    case ready(HostDirectoryListing)
}

/// Path arithmetic for host folders. Hosts may be POSIX or Windows machines.
enum HostPath {
    private static func separatorFor(_ path: String) -> String {
        !path.contains("/") && path.contains("\\") ? "\\" : "/"
    }

    private static func isDrive(_ path: String) -> Bool {
        path.count == 2 && path.hasSuffix(":") && (path.first?.isLetter ?? false)
    }

    private static func isDriveRoot(_ path: String) -> Bool {
        path.count == 3 && path.hasSuffix(":\\") && (path.first?.isLetter ?? false)
    }

    static func parent(_ path: String) -> String? {
        let separator: String = separatorFor(path)
        var trimmed: String = path
        if trimmed.count > 1 && trimmed.hasSuffix(separator) && !isDriveRoot(trimmed) { trimmed.removeLast() }
        if trimmed.isEmpty || trimmed == "/" || trimmed == "~" || isDrive(trimmed) || isDriveRoot(trimmed) { return nil }
        guard let range = trimmed.range(of: separator, options: .backwards) else { return nil }
        let parent = String(trimmed[..<range.lowerBound])
        if parent.isEmpty { return separator }
        return isDrive(parent) ? parent + "\\" : parent
    }

    static func child(_ path: String, _ name: String) -> String {
        let separator: String = separatorFor(path)
        return path.hasSuffix(separator) ? path + name : path + separator + name
    }

    static func lastComponent(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }
}

enum SSHCommand {
    /// Accepts `ssh user@host -p 2222` or just `user@host -p 2222`, like Zed's Connect SSH Server dialog.
    static func normalized(_ text: String) -> String {
        let command: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty || command == "ssh" { return "" }
        if command.hasPrefix("ssh ") || command.hasPrefix("ssh\t") { return command }
        return "ssh " + command
    }
}
