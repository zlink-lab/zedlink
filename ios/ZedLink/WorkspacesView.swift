import SwiftUI

// Hosts, projects and agent-thread history reported by desktop Zed, opened the way
// Zed's own sidebar opens them. Bodies stay small: Swift 6.1 times out on large ones.

struct WorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    /// Set to a thread id that `thread.list` exposes; the presenter navigates after dismissal.
    @Binding var openedThreadID: String?
    @State private var expanded: Set<String> = []
    @State private var browsingHost: WorkspaceHost?
    @State private var showingAddServer = false
    @State private var addedHostID: String?
    @State private var newSessionLocation: WorkspaceLocation?
    @State private var createdThreadID: String?

    var body: some View {
        NavigationStack {
            hostList
                .navigationTitle("Workspaces")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { workspacesToolbar }
                .sheet(item: $browsingHost) { host in HostFolderBrowser(host: host) }
                .sheet(isPresented: $showingAddServer, onDismiss: { browseAddedHost() }) {
                    AddSSHServerView(addedHostID: $addedHostID)
                }
                .sheet(item: $newSessionLocation, onDismiss: { openCreatedThread() }) { location in
                    NewSessionView(workspace: location) { createdThreadID = $0 }
                }
                .task { await loadInitial() }
                .refreshable { await session.loadWorkspaces() }
        }
    }

    private var canBrowse: Bool {
        session.capabilities.contains("host.directory") && session.capabilities.contains("workspace.open")
    }

    private var hostList: some View {
        List {
            statusSection
            // SSH connections Zed saved without a project (bare IPs) are hidden.
            ForEach(session.visibleWorkspaceHosts) { host in
                hostSection(host)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private var statusSection: some View {
        if let progress = session.workspaceProgress {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress).font(.subheadline)
                }
            }
        }
        if !session.workspaceIssue.isEmpty {
            Section {
                Text(session.workspaceIssue).font(.subheadline).foregroundStyle(ZLTheme.warning)
            }
        }
        if session.workspaceHosts.isEmpty && session.workspaceProgress == nil {
            Section {
                Text(session.workspaceLoaded ? "Desktop Zed reported no hosts." : "Loading hosts and projects…")
                    .font(.subheadline).foregroundStyle(ZLTheme.muted)
            }
        }
    }

    private func hostSection(_ host: WorkspaceHost) -> some View {
        Section {
            ForEach(host.projects) { project in
                WorkspaceProjectRow(host: host, project: project, expanded: expandedBinding(project.id),
                                    onOpenThread: { openThread($0) },
                                    onNewThread: { newSessionLocation = WorkspaceLocation(host: host, project: project) })
            }
            if host.projects.isEmpty {
                Text("No projects yet.").font(.subheadline).foregroundStyle(ZLTheme.muted)
            }
            if canBrowse {
                Button { browsingHost = host } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                }.accessibilityIdentifier("workspace-browse-" + host.id)
            }
        } header: {
            WorkspaceHostHeader(host: host)
        }
    }

    @ToolbarContentBuilder private var workspacesToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if session.capabilities.contains("host.add") {
                Button { showingAddServer = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add SSH server")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await session.loadWorkspaces() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Refresh workspaces")
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func loadInitial() async {
        session.clearWorkspaceIssue()
        await session.loadWorkspaces()
        if expanded.isEmpty, let first = session.workspaceHosts.first?.projects.first {
            expanded.insert(first.id)
        }
    }

    private func openThread(_ thread: WorkspaceHistoryThread) {
        Task {
            guard let id = await session.openHistoryThread(thread) else { return }
            openedThreadID = id
            dismiss()
        }
    }

    /// After the new-session sheet closes, hand the thread to the Sessions stack and close Workspaces.
    private func openCreatedThread() {
        guard let id = createdThreadID else { return }
        createdThreadID = nil
        openedThreadID = id
        dismiss()
    }

    private func browseAddedHost() {
        guard let id = addedHostID else { return }
        addedHostID = nil
        if canBrowse, let host = session.workspaceHosts.first(where: { $0.id == id }) {
            browsingHost = host
        }
    }
}

private struct WorkspaceHostHeader: View {
    let host: WorkspaceHost

    private var detail: String {
        var parts: [String] = []
        if host.isSSH { parts.append("SSH") } else if host.label != "This computer" { parts.append("This computer") }
        if let value = host.detail { parts.append(value) }
        if host.isSSH { parts.append(host.connected ? "Connected" : "Not connected") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(host.label, systemImage: host.isSSH ? "server.rack" : "desktopcomputer")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ZLTheme.ink)
            Text(detail).font(.caption).foregroundStyle(host.connected ? ZLTheme.healthy : ZLTheme.muted)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceProjectRow: View {
    @EnvironmentObject private var session: SessionManager
    let host: WorkspaceHost
    let project: WorkspaceProject
    @Binding var expanded: Bool
    let onOpenThread: (WorkspaceHistoryThread) -> Void
    let onNewThread: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            threadRows
        } label: {
            projectLabel
        }
        .accessibilityIdentifier("workspace-project-" + project.id)
    }

    private var summary: String {
        let count: Int = project.threads.count
        return (project.open ? "Open" : "Closed") + " · \(count) thread" + (count == 1 ? "" : "s")
    }

    private var projectLabel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.body.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(1)
                Text(project.paths.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(ZLTheme.muted).lineLimit(2)
                Text(summary).font(.caption).foregroundStyle(project.open ? ZLTheme.healthy : ZLTheme.muted)
            }
            Spacer(minLength: 8)
            openButton
            newThreadButton
        }
    }

    /// Opens the workspace first when it is closed, then creates a thread with the chosen agent.
    @ViewBuilder private var newThreadButton: some View {
        if session.capabilities.contains("thread.create") && (project.open || session.capabilities.contains("workspace.open")) {
            Button { onNewThread() } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(session.workspaceProgress != nil || session.creatingThread)
            .accessibilityLabel("New session in \(project.name)")
            .accessibilityIdentifier("workspace-new-thread-" + project.id)
        }
    }

    @ViewBuilder private var openButton: some View {
        if !project.open && session.capabilities.contains("workspace.open") {
            Button("Open") {
                Task { _ = await session.openWorkspace(host: host, paths: project.paths, name: project.name) }
            }
            .buttonStyle(.bordered)
            .disabled(session.workspaceProgress != nil)
            .accessibilityLabel("Open \(project.name) in Zed")
        }
    }

    @ViewBuilder private var threadRows: some View {
        if project.threads.isEmpty {
            Text("No agent threads in this project.").font(.subheadline).foregroundStyle(ZLTheme.muted)
        }
        ForEach(project.threads) { thread in
            Button { onOpenThread(thread) } label: { WorkspaceThreadLabel(thread: thread) }
                .buttonStyle(.plain)
                .disabled(!canOpen(thread))
                .accessibilityIdentifier("workspace-thread-" + thread.id)
        }
    }

    private func canOpen(_ thread: WorkspaceHistoryThread) -> Bool {
        guard session.workspaceProgress == nil else { return false }
        let exposed: Bool = session.threads.contains(where: { $0.id == thread.id })
        return (thread.loaded && exposed) || session.capabilities.contains("thread.open")
    }
}

private struct WorkspaceThreadLabel: View {
    @EnvironmentObject private var session: SessionManager
    let thread: WorkspaceHistoryThread

    private var meta: String {
        var parts: [String] = [session.agentDisplayName(thread.agent)]
        if let date = thread.updatedAt { parts.append(date.formatted(.relative(presentation: .named))) }
        if !thread.loaded { parts.append("Not loaded") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title ?? "Untitled thread")
                    .font(.subheadline.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(meta).font(.caption).foregroundStyle(ZLTheme.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ZLTheme.muted)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: Folder browser (host.directory, then workspace.open)

struct HostFolderBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    let host: WorkspaceHost
    @State private var requestedPath = "~"
    @State private var reload = 0
    @State private var phase: HostDirectoryState = .loading
    @State private var failure = ""
    @State private var opening = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                entriesSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(host.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .safeAreaInset(edge: .bottom) { openBar }
            .task(id: loadID) { await load() }
        }
    }

    private var loadID: String { requestedPath + "\n" + String(reload) }

    private var listing: HostDirectoryListing? {
        guard case .ready(let value) = phase else { return nil }
        return value
    }

    private var phaseText: String {
        phase == .connecting ? "Connecting to \(host.label)…" : "Loading folder…"
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            Text(listing?.path ?? requestedPath).font(.caption.monospaced()).textSelection(.enabled)
            if let progress = session.workspaceProgress {
                Text(progress).font(.subheadline)
            }
            if !failure.isEmpty {
                Text(failure).font(.subheadline).foregroundStyle(ZLTheme.warning)
            } else if listing == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(phaseText).font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var entriesSection: some View {
        if let listing {
            Section {
                if let parent = HostPath.parent(listing.path) {
                    Button { requestedPath = parent } label: { Label("..", systemImage: "arrow.up") }
                        .accessibilityLabel("Parent folder")
                }
                ForEach(listing.entries) { entry in
                    entryRow(entry, in: listing.path)
                }
                if listing.entries.isEmpty {
                    Text("This folder is empty.").font(.subheadline).foregroundStyle(ZLTheme.muted)
                }
            }
        }
    }

    @ViewBuilder private func entryRow(_ entry: HostDirectoryEntry, in path: String) -> some View {
        if entry.isDirectory {
            Button { requestedPath = HostPath.child(path, entry.name) } label: {
                Label(entry.name, systemImage: "folder")
            }
        } else {
            Label(entry.name, systemImage: "doc").foregroundStyle(ZLTheme.muted)
        }
    }

    @ViewBuilder private var openBar: some View {
        if let listing {
            Button { open(listing.path) } label: {
                Text(opening ? "Opening…" : "Open this folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(ZLPrimaryButtonStyle())
            .disabled(opening || session.workspaceProgress != nil)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(ZLTheme.surface)
            .accessibilityIdentifier("open-host-folder")
        }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Reload folder")
        }
    }

    private func load() async {
        let path: String = requestedPath
        failure = ""
        phase = .loading
        for _ in 0..<90 {
            do {
                let next: HostDirectoryState = try await session.hostDirectory(hostID: host.id, path: path)
                if Task.isCancelled { return }
                phase = next
                // ".." and child folders are derived from the resolved absolute path, not "~".
                if case .ready = next { return }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
                return
            }
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
        }
        failure = "\(host.label) did not respond. Check desktop Zed, then reload."
    }

    private func open(_ path: String) {
        opening = true
        failure = ""
        Task {
            let opened: Bool = await session.openWorkspace(host: host, paths: [path], name: HostPath.lastComponent(path))
            opening = false
            if opened { dismiss() } else { failure = session.workspaceIssue }
        }
    }
}

// MARK: Add SSH server (host.add)

struct AddSSHServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @Binding var addedHostID: String?
    @State private var command = ""
    @State private var adding = false
    @State private var failure = ""

    var body: some View {
        NavigationStack {
            Form {
                commandSection
                failureSection
            }
            .navigationTitle("Add SSH server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { addToolbar }
        }
    }

    private var normalized: String { SSHCommand.normalized(command) }

    private var commandSection: some View {
        Section {
            TextField("ssh user@host -p 2222", text: $command)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .submitLabel(.done)
                .onSubmit { add() }
                .accessibilityIdentifier("ssh-command")
        } header: {
            Text("SSH command")
        } footer: {
            Text("Zed saves this server like its Connect SSH Server dialog. If a password is needed, Zed asks on the desktop.")
        }
    }

    @ViewBuilder private var failureSection: some View {
        if !failure.isEmpty {
            Section {
                Text(failure).foregroundStyle(ZLTheme.warning)
            }
        }
    }

    @ToolbarContentBuilder private var addToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(adding ? "Adding…" : "Add") { add() }
                .disabled(adding || normalized.isEmpty)
        }
    }

    private func add() {
        let value: String = normalized
        guard !value.isEmpty, !adding else { return }
        adding = true
        failure = ""
        Task {
            do {
                let hostID: String = try await session.addHost(command: value)
                adding = false
                addedHostID = hostID
                dismiss()
            } catch {
                adding = false
                failure = error.localizedDescription
            }
        }
    }
}
