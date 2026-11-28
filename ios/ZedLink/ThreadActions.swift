import SwiftUI

/// What a thread row knows about its thread: enough for the long-press menu, the info sheet and
/// "go to workspace" on any connection.
struct ThreadRef: Identifiable, Equatable {
    let gatewayID: String
    let targetID: String
    let threadID: String
    var title: String
    var connectionName: String
    var hostID: String? = nil
    var hostLabel: String? = nil
    var projectID: String? = nil
    var workspaceLabel: String? = nil
    var paths: [String] = []
    var agent: String? = nil
    var state: String? = nil
    var updated: Date? = nil

    var id: String { [gatewayID.lowercased(), targetID, threadID].joined(separator: "\n") }
    /// The same key the Sessions list pins by, so a pin shows on both tabs.
    var pinKey: String { SessionLibrary.key(profile: gatewayID, target: targetID, thread: threadID) }
}

extension ThreadRef {
    init(entry: SummaryEntry) {
        self.init(gatewayID: entry.gatewayID, targetID: entry.targetID, threadID: entry.threadID, title: entry.title,
                  connectionName: entry.connectionName, hostID: entry.hostID, hostLabel: entry.hostLabel,
                  projectID: entry.projectID, workspaceLabel: entry.workspaceLabel, agent: entry.agent,
                  state: entry.status.label, updated: entry.updatedAt)
    }
}

extension SessionManager {
    /// A thread of the connected target; nil while no connection is selected.
    func threadRef(_ threadID: String) -> ThreadRef? {
        guard let profile, let targetID else { return nil }
        let thread: NativeThread? = visibleThreads.first { $0.id == threadID }
        let history: RecentHistoryThread? = historyThread(threadID)
        let location: WorkspaceLocation? = thread.flatMap { workspaceLocation(for: $0) }
        return ThreadRef(gatewayID: profile.gatewayID, targetID: targetID, threadID: threadID,
                         title: thread?.title ?? history?.thread.title ?? "Тред",
                         connectionName: profile.name,
                         hostID: thread?.hostID ?? location?.host.id ?? history?.hostID,
                         hostLabel: thread?.hostLabel ?? location?.host.label ?? history?.hostLabel,
                         projectID: thread?.projectID ?? location?.project.id ?? history?.projectID,
                         workspaceLabel: thread?.workspaceLabel ?? location?.project.name ?? history?.project ?? thread?.project,
                         paths: thread?.workspacePaths ?? location?.project.paths ?? [],
                         agent: thread?.agentName ?? history.map { agentDisplayName($0.thread.agent) },
                         state: thread?.status,
                         updated: history?.thread.updatedAt)
    }
}

/// Long press on a thread row: pin, go to its workspace, see its parameters.
struct ThreadActionsMenu: ViewModifier {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var library: SessionLibrary
    @EnvironmentObject private var profiles: ProfileStore
    let ref: ThreadRef?
    @Binding var info: ThreadRef?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let ref {
                let pinned: Bool = library.pins.contains(ref.pinKey)
                Button(pinned ? "Открепить" : "Закрепить", systemImage: pinned ? "pin.slash" : "pin") {
                    library.toggle(ref.pinKey)
                }
                Button("Перейти в воркспейс", systemImage: "folder") {
                    Task { await session.showWorkspace(of: ref, profiles: profiles.profiles) }
                }
                .disabled(session.demoPreview)
                Button("Параметры треда", systemImage: "info.circle") { info = ref }
            }
        }
    }
}

extension View {
    func threadActions(_ ref: ThreadRef?, info: Binding<ThreadRef?>) -> some View {
        modifier(ThreadActionsMenu(ref: ref, info: info))
    }
}

struct ThreadInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var library: SessionLibrary
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var extras: GatewayExtrasStore
    let ref: ThreadRef

    private var profile: ConnectionProfile? {
        GatewayExtrasStore.route(gatewayID: ref.gatewayID, in: profiles.profiles, preferring: session.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ref.title).font(.subheadline.weight(.medium))
                    row("Состояние", ref.state)
                    row("Агент", ref.agent)
                    row("Изменён", ref.updated.map { $0.formatted(date: .abbreviated, time: .shortened) })
                }
                Section("Где") {
                    row("Подключение", ref.connectionName)
                    row("Хост", ref.hostLabel)
                    row("Воркспейс", ref.workspaceLabel)
                    ForEach(ref.paths, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    row("ID треда", ref.threadID)
                }
                if let status = extras.autopilotStatus(gatewayID: ref.gatewayID) {
                    Section("Автопилот") {
                        Text(status.summary(targetID: ref.targetID, threadID: ref.threadID).statusText).font(.footnote)
                    }
                }
                Section {
                    Button(library.pins.contains(ref.pinKey) ? "Открепить" : "Закрепить", systemImage: "pin") {
                        library.toggle(ref.pinKey)
                    }
                    Button("Перейти в воркспейс", systemImage: "folder") {
                        let target: ThreadRef = ref
                        dismiss()
                        Task { await session.showWorkspace(of: target, profiles: profiles.profiles) }
                    }
                    .disabled(session.demoPreview)
                    if let profile {
                        NavigationLink {
                            ThreadStatsView(profile: profile, targetID: ref.targetID, threadID: ref.threadID, title: ref.title)
                        } label: { Label("Токены", systemImage: "chart.bar") }
                    }
                }
            }
            .navigationTitle("Параметры треда").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }

    @ViewBuilder private func row(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(name) { Text(value).textSelection(.enabled) }
        }
    }
}
