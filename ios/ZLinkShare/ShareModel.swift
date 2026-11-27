import Foundation
import UniformTypeIdentifiers

/// A shared file, copied into the extension's temporary folder so it is read one at a time.
struct SharedFile: Identifiable {
    let id = UUID()
    let fileName: String
    let mimeType: String
    let url: URL
    let size: Int
}

/// A thread the share can go to: listed by Zed now, or known from the workspace's history.
struct ShareThread: Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Date?
    let listed: Bool
}

/// Connection → Zed target → host → workspace → thread, then uploads and `thread.send`.
/// Uses the same gateway calls as the app: `project.upload.*` and `thread.send` with `upload_refs`.
@MainActor final class ShareModel: ObservableObject {
    static let newThread = "new-thread"
    /// Shares bigger than this go through the App Group to the app, which uploads them.
    static let handoffBytes = 10 * 1024 * 1024

    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var profileID = ""
    @Published private(set) var targets: [ZedTarget] = []
    @Published var targetID = ""
    @Published private(set) var hosts: [WorkspaceHost] = []
    @Published var hostID = ""
    @Published var projectID = ""
    @Published private(set) var threads: [ShareThread] = []
    @Published var threadChoice = ShareModel.newThread
    @Published var comment = ""
    @Published private(set) var files: [SharedFile] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var sending = false
    @Published private(set) var progress: Double?
    @Published private(set) var done = false
    var finish: ((Bool) -> Void)?

    private var client: GatewayClient?
    private var instanceID = ""
    private var epoch = ""
    private var capabilities: Set<String> = []
    private var listedRows: [[String: Any]] = []
    private var generation = UUID()

    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
    var profile: ConnectionProfile? { profiles.first { $0.id.uuidString == profileID } }
    var host: WorkspaceHost? { hosts.first { $0.id == hostID } }
    var project: WorkspaceProject? { host?.projects.first { $0.id == projectID } }
    var canSend: Bool {
        !sending && !done && client != nil && !projectID.isEmpty && (!files.isEmpty || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Shared items

    func loadItems(from providers: [NSItemProvider]) async {
        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                provider.registeredTypeIdentifiers.contains(where: { identifier in
                    guard let type = UTType(identifier) else { return false }
                    return type.conforms(to: .data) && !type.conforms(to: .plainText) && !type.conforms(to: .url)
                }) {
                if let file = await copyFile(from: provider) { files.append(file) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(from: provider) { texts.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(from: provider) { texts.append(text) }
            }
        }
        if !texts.isEmpty { comment = texts.joined(separator: "\n") }
        if files.contains(where: { $0.size > ProjectUploader.maxBytes }) {
            files.removeAll { $0.size > ProjectUploader.maxBytes }
            status = "Files over 25 MiB were left out."
        }
    }

    private func copyFile(from provider: NSItemProvider) async -> SharedFile? {
        let identifier: String = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .data) == true
        }) ?? UTType.data.identifier
        let suggested: String? = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<SharedFile?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                // The provided URL is valid only inside this callback: copy it out.
                guard let url else { continuation.resume(returning: nil); return }
                let type: UTType? = UTType(identifier)
                var name: String = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += "." + ext }
                let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy: URL = folder.appendingPathComponent(ProjectUploader.cleanFileName(name))
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    let size: Int = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let mime: String = type?.preferredMIMEType ?? ProjectUploader.mimeType(forFileName: copy.lastPathComponent)
                    continuation.resume(returning: SharedFile(fileName: copy.lastPathComponent, mimeType: mime, url: copy, size: size))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    // MARK: Destination

    func start() async {
        let shared = SharedProfiles.load()
        profiles = shared.profiles
        guard !profiles.isEmpty else {
            status = AppGroup.isAvailable
                ? "Open ZLink Lab and pair a connection first."
                : "This build of ZLink Lab has no shared App Group; sharing is unavailable."
            return
        }
        profileID = (shared.lastUsed.flatMap { id in profiles.first { $0.id == id } } ?? profiles[0]).id.uuidString
        await profileChanged()
    }

    func profileChanged() async {
        guard let profile else { return }
        let current = UUID(); generation = current
        client = nil; targets = []; targetID = ""; hosts = []; hostID = ""; projectID = ""; threads = []
        loading = true
        defer { if generation == current { loading = false } }
        do {
            guard let token = await CredentialVault.shared.read(profile) else {
                throw GatewayFailure.native("This iPhone is not paired with \(profile.name). Pair it in ZLink Lab.")
            }
            let registry = try await GatewayClient(profile: profile, token: token).rpc("instance.list")
            guard generation == current else { return }
            targets = (registry["targets"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["target_id"] as? String, let label = row["label"] as? String else { return nil }
                return ZedTarget(id: id, label: label, available: row["available"] as? Bool ?? false)
            }
            guard let target = targets.first(where: { $0.available }) else {
                throw GatewayFailure.native("Desktop Zed is not running for \(profile.name).")
            }
            targetID = target.id
            status = ""
            await targetChanged()
        } catch {
            if generation == current { status = error.localizedDescription }
        }
    }

    func targetChanged() async {
        guard let profile, !targetID.isEmpty else { return }
        let current = UUID(); generation = current
        client = nil; hosts = []; hostID = ""; projectID = ""; threads = []
        loading = true
        defer { if generation == current { loading = false } }
        do {
            guard let token = await CredentialVault.shared.read(profile) else { throw GatewayFailure.native("UNAUTHENTICATED") }
            let next = GatewayClient(profile: profile, token: token, targetID: targetID)
            let info = try await next.rpc("instance.info")
            guard generation == current else { return }
            guard let instance = info["instance_id"] as? String, let currentEpoch = info["epoch"] as? String else {
                throw GatewayFailure.invalidResponse
            }
            instanceID = instance; epoch = currentEpoch
            capabilities = Set(info["capabilities"] as? [String] ?? [])
            guard capabilities.contains(ProjectUploader.capability), capabilities.contains("workspace.list") else {
                throw GatewayFailure.native("Update desktop Zed: this version does not accept shared files.")
            }
            let workspaces = try await next.rpc("workspace.list", params: ["instance_id": instance, "epoch": currentEpoch])
            let list = try await next.rpc("thread.list")
            guard generation == current else { return }
            listedRows = list["threads"] as? [[String: Any]] ?? []
            hosts = (workspaces["hosts"] as? [[String: Any]] ?? []).compactMap { WorkspaceHost(row: $0) }
                .filter { !$0.projects.isEmpty }
            client = next
            // The workspace with the most recent thread first.
            let newest: RecentHistoryThread? = RecentHistoryThread.recent(in: hosts).first
            hostID = newest?.hostID ?? hosts.first?.id ?? ""
            projectID = newest?.projectID ?? host?.projects.first?.id ?? ""
            rebuildThreads()
            status = hosts.isEmpty ? "Desktop Zed reported no workspaces." : ""
        } catch {
            if generation == current { status = error.localizedDescription }
        }
    }

    func hostChanged() {
        if host?.projects.contains(where: { $0.id == projectID }) != true { projectID = host?.projects.first?.id ?? "" }
        rebuildThreads()
    }

    /// Recent first: the workspace's history (newest first), plus listed threads it does not name.
    func rebuildThreads() {
        guard let project else { threads = []; threadChoice = Self.newThread; return }
        var rows: [ShareThread] = []
        var seen: Set<String> = []
        let listedIDs: Set<String> = Set(listedRows.compactMap { $0["thread_id"] as? String })
        for thread in project.threads.sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) {
            seen.insert(thread.id)
            rows.append(ShareThread(id: thread.id, title: thread.title ?? "Untitled thread", updatedAt: thread.updatedAt,
                                    listed: listedIDs.contains(thread.id)))
        }
        for row in listedRows {
            guard let id = row["thread_id"] as? String, !seen.contains(id), row["project_id"] as? String == project.id else { continue }
            rows.insert(ShareThread(id: id, title: row["title"] as? String ?? "Untitled Agent thread", updatedAt: nil, listed: true), at: 0)
        }
        threads = rows
        if !rows.contains(where: { $0.id == threadChoice }) { threadChoice = Self.newThread }
    }

    // MARK: Send

    func send() async {
        guard canSend, let client, let profile, let host, let project else { return }
        sending = true
        progress = nil
        defer { sending = false }
        do {
            let threadID: String = try await resolveThread(client: client, host: host, project: project)
            let text: String = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if totalBytes > Self.handoffBytes && AppGroup.isAvailable {
                let item = SharedInboxItem(gatewayID: profile.gatewayID, targetID: targetID, threadID: threadID,
                                           threadTitle: threads.first(where: { $0.id == threadID })?.title ?? project.name,
                                           text: text,
                                           files: files.map { SharedInboxItem.File(fileName: $0.fileName, mimeType: $0.mimeType, storedName: $0.id.uuidString) })
                try SharedInbox.save(item, copying: files.map { (storedName: $0.id.uuidString, url: $0.url) })
                status = "Large files were handed to ZLink Lab. Open the app to finish sending them."
                done = true
                return
            }
            var refs: [String] = []
            for (index, file) in files.enumerated() {
                status = "Uploading \(file.fileName)…"
                let data: Data = try Data(contentsOf: file.url)
                let prepared = ProjectUploader.prepare(fileName: file.fileName, mimeType: file.mimeType, data: data)
                let count = Double(files.count)
                let committed = try await ProjectUploader.upload(client: client, instanceID: instanceID, epoch: epoch,
                                                                 threadID: threadID, projectID: nil, file: prepared) { [weak self] fraction in
                    self?.progress = (Double(index) + fraction) / count
                }
                refs.append(committed.ref)
            }
            status = "Sending…"
            var params: [String: Any] = ["instance_id": instanceID, "epoch": epoch, "thread_id": threadID, "text": text]
            if !refs.isEmpty { params["upload_refs"] = Array(refs.prefix(ProjectUploader.maxRefsPerMessage)) }
            _ = try await client.rpc("thread.send", params: params)
            status = "Sent to \(project.name)."
            done = true
            try? await Task.sleep(for: .milliseconds(700))
            finish?(false)
        } catch {
            status = ProjectUploader.describe(error)
        }
    }

    /// The chosen thread id: a new thread in the workspace (opened first when closed), or an
    /// existing one, loaded with `thread.open` when Zed has not loaded it yet.
    private func resolveThread(client: GatewayClient, host: WorkspaceHost, project: WorkspaceProject) async throws -> String {
        let base: [String: Any] = ["instance_id": instanceID, "epoch": epoch]
        if threadChoice != Self.newThread {
            if threads.first(where: { $0.id == threadChoice })?.listed == true { return threadChoice }
            guard capabilities.contains("thread.open") else { throw GatewayFailure.native("Open this thread in desktop Zed first.") }
            status = "Loading the thread in Zed…"
            _ = try await client.rpc("thread.open", params: base.merging(["thread_id": threadChoice]) { _, new in new })
            for _ in 0..<45 {
                let list = try await client.rpc("thread.list")
                if (list["threads"] as? [[String: Any]] ?? []).contains(where: { $0["thread_id"] as? String == threadChoice }) {
                    return threadChoice
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw GatewayFailure.native("Zed has not loaded this thread yet (THREAD_NOT_LOADED).")
        }
        guard capabilities.contains("thread.create") else { throw GatewayFailure.native("This Zed version cannot create threads from the phone.") }
        if !project.open {
            guard capabilities.contains("workspace.open") else { throw GatewayFailure.native("Open \(project.name) in desktop Zed first.") }
            status = "Opening \(project.name) in Zed…"
            _ = try await client.rpc("workspace.open", params: base.merging(["host_id": host.id, "paths": project.paths]) { _, new in new })
            var opened = false
            for _ in 0..<40 where !opened {
                try await Task.sleep(for: .milliseconds(1500))
                let result = try await client.rpc("workspace.list", params: base)
                let rows: [WorkspaceHost] = (result["hosts"] as? [[String: Any]] ?? []).compactMap { WorkspaceHost(row: $0) }
                opened = rows.first(where: { $0.id == host.id })?.projects.first(where: { $0.paths == project.paths })?.open == true
            }
            guard opened else { throw GatewayFailure.native("Zed is still opening \(project.name). Try again in a moment.") }
        }
        status = "Creating a thread…"
        var agentID = "zed-agent"
        if capabilities.contains("thread.create.options"),
           let options = try? await client.rpc("thread.create.options", params: base),
           let first = (options["agents"] as? [[String: Any]])?.first?["id"] as? String {
            agentID = first
        }
        var params: [String: Any] = base
        params["title"] = NSNull()
        params["agent_id"] = agentID
        params["host_id"] = host.id
        params["project_id"] = project.id
        params["workspace_paths"] = project.paths
        let requestID = UUID().uuidString
        for _ in 0..<40 {
            let result = try await client.rpc("thread.create", params: params, requestID: requestID)
            if result["outcome"] as? String == "ready", let id = result["thread_id"] as? String { return id }
            guard result["outcome"] as? String == "creating" else { throw GatewayFailure.invalidResponse }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GatewayFailure.native("Zed is still creating the thread. Try again in a moment.")
    }

    func cancel() { finish?(true) }
}
