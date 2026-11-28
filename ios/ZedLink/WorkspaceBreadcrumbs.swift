import SwiftUI

// The Sessions header crumb: connection › host › workspace (host and workspace from
// `workspace.list`), which also filters the sessions list. Bodies stay small: Swift 6.1 times out on large view expressions.

struct WorkspaceBreadcrumbMenu: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        Menu {
            allWorkspacesButton
            ForEach(session.visibleWorkspaceHosts) { host in
                WorkspaceHostMenu(host: host)
            }
            if session.workspaceHosts.isEmpty && session.supportsWorkspaces {
                Text(session.workspaceLoaded ? "Desktop Zed reported no hosts" : "Loading workspaces…")
            }
            targetSection
            connectionSection
        } label: {
            crumbLabel
        }
        .accessibilityIdentifier("zed-target-picker")
        .accessibilityLabel("Connection and workspace: " + crumbAccessibilityText)
    }

    /// `connection › host › workspace`; "All workspaces" when no host is chosen.
    private var crumbParts: [String] {
        guard let profile = session.profile else { return ["Choose a connection"] }
        var parts: [String] = [profile.name]
        if let filter = session.workspaceFilter {
            parts.append(filter.hostLabel)
            parts.append(filter.projectName ?? "All workspaces")
        } else if !session.supportsWorkspaces, let target = session.targets.first(where: { $0.id == session.targetID }) {
            parts.append(target.label)
        } else {
            parts.append("All workspaces")
        }
        return parts
    }

    private var crumbAccessibilityText: String { crumbParts.joined(separator: ", ") }

    private var crumbLabel: some View {
        let parts: [String] = crumbParts
        return HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2) }
                Text(part).lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.caption).frame(minHeight: 44).foregroundStyle(ZLTheme.ink)
    }

    @ViewBuilder private var allWorkspacesButton: some View {
        if session.profile != nil && session.supportsWorkspaces {
            Button { session.setWorkspaceFilter(nil) } label: {
                Label("All workspaces", systemImage: session.workspaceFilter == nil ? "checkmark" : "square.stack.3d.up")
            }
            .accessibilityIdentifier("workspace-filter-all")
        }
    }

    /// Zed instances advertised by the gateway (kept from the previous crumb).
    @ViewBuilder private var targetSection: some View {
        if session.profile != nil && (session.targets.count > 1 || !session.supportsWorkspaces) {
            Section("Zed instance") {
                ForEach(session.targets) { target in
                    Button { Task { await session.selectTarget(target.id) } } label: {
                        Label(target.label + (target.available ? "" : " · unavailable"),
                              systemImage: target.id == session.targetID ? "checkmark" : "macwindow")
                    }
                    .disabled(!target.available || session.demoPreview)
                }
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        Section {
            if let profile = session.profile {
                Text(profile.name)
                Text(session.activeEndpoint ?? profile.endpoint)
                if profile.endpoints.count > 1, let route = session.activeRouteLabel { Text(route) }
            }
            Button("Manage connections", systemImage: "link") { session.showConnections = true }
        }
    }
}

private struct WorkspaceHostMenu: View {
    @EnvironmentObject private var session: SessionManager
    let host: WorkspaceHost

    private var openProjects: [WorkspaceProject] { host.projects.filter(\.open) }
    private var closedProjects: [WorkspaceProject] { host.projects.filter { !$0.open } }
    private var selectedHost: Bool { session.workspaceFilter?.hostID == host.id }

    var body: some View {
        Menu {
            Button { selectHost() } label: {
                Label("All on \(host.label)", systemImage: selectedHost && session.workspaceFilter?.projectID == nil ? "checkmark" : "tray.full")
            }
            if !openProjects.isEmpty {
                Section("Open") {
                    ForEach(openProjects) { project in projectButton(project) }
                }
            }
            if !closedProjects.isEmpty {
                Section("Closed · opens in Zed") {
                    ForEach(closedProjects) { project in projectButton(project) }
                }
            }
            if host.projects.isEmpty { Text("No workspaces yet") }
        } label: {
            Label(host.label, systemImage: hostIcon)
        }
    }

    private var hostIcon: String {
        if selectedHost { return "checkmark" }
        return host.isSSH ? "server.rack" : "desktopcomputer"
    }

    private func icon(_ project: WorkspaceProject) -> String {
        if session.workspaceFilter?.projectID == project.id && selectedHost { return "checkmark" }
        return project.open ? "folder.fill" : "folder"
    }

    private func subtitle(_ project: WorkspaceProject) -> String {
        let count: Int = project.threads.count
        let threads: String = "\(count) thread" + (count == 1 ? "" : "s")
        return project.open ? threads : "Closed · " + threads
    }

    private func projectButton(_ project: WorkspaceProject) -> some View {
        Button { select(project) } label: {
            Label(project.name, systemImage: icon(project))
            Text(subtitle(project))
        }
        .disabled(!project.open && (!session.capabilities.contains("workspace.open") || session.workspaceProgress != nil))
        .accessibilityIdentifier("workspace-filter-" + project.id)
    }

    private func selectHost() {
        session.setWorkspaceFilter(WorkspaceFilter(hostID: host.id, hostLabel: host.label))
    }

    private func select(_ project: WorkspaceProject) {
        session.setWorkspaceFilter(WorkspaceFilter(hostID: host.id, hostLabel: host.label,
                                                   projectID: project.id, projectName: project.name))
        guard !project.open else { return }
        session.clearWorkspaceIssue()
        let host: WorkspaceHost = self.host
        Task { _ = await session.openWorkspace(host: host, paths: project.paths, name: project.name) }
    }
}
