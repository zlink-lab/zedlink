import Foundation
import Combine

/// Finishes shares the ZLinkShare extension handed over through the App Group (files too large
/// for the extension's short lifetime): uploads them into the thread's project and sends the
/// message. The manifest id is the `thread.send` request id, so a retry after a crash cannot
/// create a second turn. Does nothing in builds without the App Group.
@MainActor final class SharedInboxProcessor: ObservableObject {
    static let shared = SharedInboxProcessor()
    @Published private(set) var message = ""
    private var running = false
    private let lifetime: TimeInterval = 3 * 24 * 60 * 60

    func dismissMessage() { message = "" }

    func process(profiles: [ConnectionProfile]) async {
        guard AppGroup.isAvailable, !running else { return }
        running = true
        defer { running = false }
        for item in SharedInbox.items() {
            if Date().timeIntervalSince(item.created) > lifetime {
                SharedInbox.remove(item)
                message = "A shared file for “\(item.threadTitle)” expired before it could be sent."
                continue
            }
            guard let profile = profiles.first(where: { $0.gatewayID.caseInsensitiveCompare(item.gatewayID) == .orderedSame }) else {
                SharedInbox.remove(item)
                continue
            }
            message = "Sending shared files to “\(item.threadTitle)”…"
            do {
                try await send(item, profile: profile)
                SharedInbox.remove(item)
                message = "Shared files sent to “\(item.threadTitle)”."
            } catch {
                message = "Shared files for “\(item.threadTitle)” are waiting: \(ProjectUploader.describe(error))"
            }
        }
    }

    private func send(_ item: SharedInboxItem, profile: ConnectionProfile) async throws {
        guard let token = await CredentialVault.shared.read(profile) else { throw GatewayFailure.native("Pair this device first.") }
        let client = GatewayClient(profile: profile, token: token, targetID: item.targetID)
        let info = try await client.rpc("instance.info")
        guard let instance = info["instance_id"] as? String, let epoch = info["epoch"] as? String else {
            throw GatewayFailure.invalidResponse
        }
        let capabilities = Set(info["capabilities"] as? [String] ?? [])
        guard capabilities.contains(ProjectUploader.capability) else {
            throw GatewayFailure.native("This Zed version does not accept file uploads from the phone.")
        }
        let list = try await client.rpc("thread.list")
        let listed: Bool = (list["threads"] as? [[String: Any]] ?? []).contains { $0["thread_id"] as? String == item.threadID }
        if !listed && capabilities.contains("thread.open") {
            _ = try await client.rpc("thread.open", params: ["instance_id": instance, "epoch": epoch, "thread_id": item.threadID])
            try await Task.sleep(for: .seconds(2))
        }
        var refs: [String] = []
        for file in item.files {
            guard let data = SharedInbox.data(file, of: item) else { continue }
            let prepared = ProjectUploader.prepare(fileName: file.fileName, mimeType: file.mimeType, data: data)
            let committed = try await ProjectUploader.upload(client: client, instanceID: instance, epoch: epoch,
                                                             threadID: item.threadID, projectID: nil, file: prepared) { _ in }
            refs.append(committed.ref)
        }
        var params: [String: Any] = ["instance_id": instance, "epoch": epoch, "thread_id": item.threadID, "text": item.text]
        if !refs.isEmpty { params["upload_refs"] = refs }
        _ = try await client.rpc("thread.send", params: params, requestID: item.id.uuidString)
    }
}
