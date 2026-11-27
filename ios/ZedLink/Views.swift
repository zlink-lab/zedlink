import AVFoundation
import SwiftUI
import CoreText
import UIKit
import VisionKit
import PhotosUI
import UniformTypeIdentifiers
import Combine

struct SessionsView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var library: SessionLibrary
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var inbox = SharedInboxProcessor.shared
    @State private var search = ""
    @State private var filter = "All"
    @State private var showingNewSession = false
    @State private var showingWorkspaces = false
    @State private var workspaceThreadID: String?
    @State private var createdThreadID: String?
    @State private var historyLimit = 30
    @Binding var navigationPath: [String]
    private let groups = ["Needs attention", "Running"]
    private let recentWindow: TimeInterval = 3 * 24 * 60 * 60
    private func key(_ thread: NativeThread) -> String { key(thread.id) }
    private func key(_ threadID: String) -> String {
        SessionLibrary.key(profile: session.profile?.gatewayID ?? "", target: session.targetID ?? "", thread: threadID)
    }
    /// Exposed and saved threads in the selected workspace that match the search (any tab).
    private var baseThreads: [NativeThread] {
        session.visibleThreads.filter { thread in
            session.matchesWorkspaceFilter(thread) &&
                (search.isEmpty || thread.searchText.localizedCaseInsensitiveContains(search))
        }
    }
    /// Threads for the "Needs attention" and "Running" sections under the selected tab.
    private var visibleThreads: [NativeThread] {
        guard filter != "Recent" else { return [] }
        return baseThreads.filter { thread in
            let activity = SessionActivity(thread)
            return filter == "All" || filter == "Needs attention" && activity.attention || filter == "Running" && activity.running || filter == "Pinned" && library.pins.contains(key(thread))
        }.sorted { left, right in
            let lp = library.pins.contains(key(left)), rp = library.pins.contains(key(right))
            if lp != rp { return lp }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }
    private var recentThreads: [NativeThread] {
        guard search.isEmpty, filter == "All", session.state == .live else { return [] }
        return library.recent.compactMap { recentKey in
            session.threads.first { key($0) == recentKey && session.matchesWorkspaceFilter($0) }
        }.prefix(3).map { $0 }
    }
    var body: some View {
        NavigationStack(path: $navigationPath) {
            sessionsList
                .sheet(isPresented: $showingWorkspaces, onDismiss: { openWorkspaceThread() }) {
                    WorkspacesView(openedThreadID: $workspaceThreadID)
                }
        }
    }

    private func openWorkspaceThread() {
        guard let thread = workspaceThreadID else { return }
        workspaceThreadID = nil
        dismissZedLinkKeyboard()
        navigationPath = [thread]
    }

    private func openCreatedThread() {
        guard let thread = createdThreadID else { return }
        createdThreadID = nil
        dismissZedLinkKeyboard()
        navigationPath = [thread]
    }

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                connectionHeader
                sessionNotices
                filterBar
                Hairline()
                recentSection
                emptyState
                groupedSections
                recentInZedSection
                olderHistorySection
            }.padding(.bottom, 16)
        }.background(ZLTheme.background).scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions, agents and history")
            .onSubmit(of: .search) { dismissZedLinkKeyboard() }
            .onChange(of: search) { _, _ in historyLimit = 30 }
            .onChange(of: session.workspaceFilter) { _, _ in historyLimit = 30 }
            .toolbar(.visible, for: .navigationBar).navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)
            .toolbar { sessionsToolbar }
            .sheet(isPresented: $showingNewSession, onDismiss: { openCreatedThread() }) {
                NewSessionView(workspace: session.filteredWorkspaceLocation) { createdThreadID = $0 }
            }
            .navigationDestination(for: String.self) { ConversationView(threadID: $0) }
            .onChange(of: session.threads, initial: true) { _, threads in
                library.observe(threads, profile: session.profile?.gatewayID ?? "", target: session.targetID ?? "", selected: session.selectedThreadID)
            }
            .onChange(of: session.notificationThreadID, initial: true) { _, thread in
                if let thread { dismissZedLinkKeyboard(); navigationPath = [thread]; session.notificationThreadID = nil }
            }
            .task(id: session.supportsWorkspaces && session.state == .live) {
                // The header breadcrumb and the "Recent in Zed" list both read workspace.list.
                while !Task.isCancelled && session.supportsWorkspaces && session.state == .live {
                    await session.loadWorkspaces()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .refreshable { await session.refresh(); await session.loadWorkspaces() }
    }

    // Split out of `body` because Swift 6.1 cannot type-check the combined expression in time.
    private var hasSavedOnlySessions: Bool {
        session.visibleThreads.contains(where: { thread in !session.threads.contains(where: { $0.id == thread.id }) })
    }

    private var savedSessionsText: String {
        session.state == .connecting ? "Saved sessions · reconciling with desktop Zed" : "Saved sessions · reconnect to update"
    }

    @ViewBuilder private var sessionNotices: some View {
        if session.demoPreview { Text("DEMO PREVIEW · Sample sessions, no live connection").font(.caption).foregroundStyle(ZLTheme.warning).padding(.horizontal, 16).padding(.vertical, 8) }
        if !session.issue.isEmpty { SessionIssueBanner() }
        if !inbox.message.isEmpty {
            Button { inbox.dismissMessage() } label: {
                Label(inbox.message, systemImage: "square.and.arrow.down").font(.caption).foregroundStyle(ZLTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityHint("Dismisses this message")
        }
        if let progress = session.workspaceProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.caption).foregroundStyle(ZLTheme.muted)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        } else if !session.workspaceIssue.isEmpty {
            Text(session.workspaceIssue).font(.caption).foregroundStyle(ZLTheme.warning)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        // Live, saved copies are threads Zed has not loaded; opening one loads it (thread.open).
        if hasSavedOnlySessions && session.state != .live {
            Text(savedSessionsText)
                .font(.caption).foregroundStyle(ZLTheme.warning).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var filterLabels: [String] {
        session.supportsRecentHistory ? ["All", "Needs attention", "Running", "Recent", "Pinned"] : ["All", "Needs attention", "Running", "Pinned"]
    }

    // MARK: Recent in Zed (last 3 days) and История (older)

    /// Idle, saved and history threads of the selected workspace, newest first; nothing is cut off.
    private var historyRows: [SessionHistoryRow] {
        guard ["All", "Recent", "Pinned"].contains(filter) else { return [] }
        let base: [NativeThread] = baseThreads
        let byID: [String: NativeThread] = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = Set(base.filter { SessionActivity($0).group != nil }.map(\.id))
        seen.formUnion(recentThreads.map(\.id))
        var rows: [SessionHistoryRow] = []
        if session.supportsWorkspaces {
            for item in RecentHistoryThread.recent(in: session.filteredWorkspaceHosts) where !seen.contains(item.id) {
                seen.insert(item.id)
                let thread: NativeThread? = byID[item.id]
                guard thread != nil || search.isEmpty || item.searchText.localizedCaseInsensitiveContains(search) else { continue }
                rows.append(SessionHistoryRow(id: item.id, date: item.thread.updatedAt, thread: thread, history: item))
            }
        }
        for thread in base where !seen.contains(thread.id) {
            seen.insert(thread.id)
            rows.append(SessionHistoryRow(id: thread.id, date: session.cachedConversation(thread.id)?.updatedAt, thread: thread, history: nil))
        }
        if filter == "Pinned" { rows = rows.filter { $0.thread != nil && library.pins.contains(key($0.id)) } }
        return rows
    }

    private func isRecent(_ row: SessionHistoryRow) -> Bool {
        guard let date = row.date else { return true }
        return Date().timeIntervalSince(date) <= recentWindow
    }

    @ViewBuilder private var recentInZedSection: some View {
        let rows: [SessionHistoryRow] = historyRows.filter { isRecent($0) }
        if !rows.isEmpty {
            HStack { SectionLabel("Recent in Zed"); Spacer(); Text("\(rows.count)").font(.caption.monospaced()).foregroundStyle(ZLTheme.muted) }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
            ForEach(rows) { row in historyRow(row) }
        }
    }

    @ViewBuilder private var olderHistorySection: some View {
        let rows: [SessionHistoryRow] = historyRows.filter { !isRecent($0) }
        if !rows.isEmpty {
            HStack { SectionLabel("История"); Spacer(); Text("\(rows.count)").font(.caption.monospaced()).foregroundStyle(ZLTheme.muted) }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
            ForEach(rows.prefix(historyLimit)) { row in historyRow(row) }
            if rows.count > historyLimit {
                // Pages in as the list scrolls; the button states what is still below.
                Button("Show more · \(rows.count - historyLimit) remaining") { historyLimit += 30 }
                    .font(.footnote).padding(.horizontal, 16).frame(minHeight: 44)
                    .onAppear { historyLimit += 30 }
                    .accessibilityIdentifier("history-show-more")
            }
        }
    }

    @ViewBuilder private func historyRow(_ row: SessionHistoryRow) -> some View {
        if let thread = row.thread {
            HStack(spacing: 0) {
                sessionLink(thread)
                pinButton(thread)
            }
        } else if let item = row.history {
            Button { openHistory(item.thread) } label: {
                HistoryThreadRow(item: item, agent: session.agentDisplayName(item.thread.agent))
            }.buttonStyle(.plain).disabled(session.workspaceProgress != nil || session.recoveringThreadID != nil)
                .accessibilityIdentifier("recent-thread-" + item.id)
        }
        Hairline().padding(.leading, 16)
    }

    private func openHistory(_ thread: WorkspaceHistoryThread) {
        dismissZedLinkKeyboard()
        session.clearWorkspaceIssue()
        Task {
            guard let id = await session.openHistoryThread(thread) else { return }
            navigationPath = [id]
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(filterLabels, id: \.self) { label in
                    filterButton(label)
                }
            }.padding(.horizontal, 16)
        }
    }

    private func filterButton(_ label: String) -> some View {
        let selected: Bool = filter == label
        return Button { filter = label; historyLimit = 30; dismissZedLinkKeyboard() } label: {
            Text(label).font(.subheadline).foregroundStyle(selected ? ZLTheme.ink : ZLTheme.muted)
                .frame(minHeight: 44).overlay(alignment: .bottom) { if selected { Rectangle().fill(ZLTheme.ink).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityIdentifier("session-filter-" + label)
    }

    private func isLive(_ thread: NativeThread) -> Bool {
        session.state == .live && session.threads.contains(where: { $0.id == thread.id })
    }

    private func place(_ thread: NativeThread) -> (host: String?, workspace: String?) {
        let location: WorkspaceLocation? = session.workspaceLocation(for: thread)
        let history: RecentHistoryThread? = (thread.hostLabel == nil || thread.workspaceLabel == nil) ? session.historyThread(thread.id) : nil
        let host: String? = thread.hostLabel ?? location?.host.label ?? history?.hostLabel
        let workspace: String? = thread.workspaceLabel ?? location?.project.name ?? history?.project ?? thread.project
        return (host, workspace)
    }

    private func sessionLink(_ thread: NativeThread) -> some View {
        let spot: (host: String?, workspace: String?) = place(thread)
        return NavigationLink(value: thread.id) {
            SessionRow(thread: thread, live: isLive(thread), updated: library.updated.contains(key(thread)),
                       host: spot.host, workspace: spot.workspace)
        }.buttonStyle(.plain).accessibilityIdentifier("thread-" + thread.id)
            .allowsHitTesting(!session.demoPreview)
            .simultaneousGesture(TapGesture().onEnded { dismissZedLinkKeyboard(); library.opened(key(thread)) })
    }

    @ViewBuilder private var recentSection: some View {
        if !recentThreads.isEmpty {
            SectionLabel("Recently opened").padding(.horizontal, 16).padding(.top, 8)
            ForEach(recentThreads) { thread in
                sessionLink(thread)
                Hairline().padding(.leading, 16)
            }
        }
    }

    private var emptyTitle: String {
        if session.profile == nil { return "Choose a connection" }
        if let filter = session.workspaceFilter, search.isEmpty {
            return "No sessions in " + (filter.projectName ?? filter.hostLabel)
        }
        if !session.visibleThreads.isEmpty { return "No matching sessions" }
        return session.state == .live ? "No exposed sessions" : "Sessions unavailable"
    }

    private var emptyDetail: String {
        if session.profile == nil { return "Pair a private gateway in Settings › Connections." }
        if session.workspaceFilter != nil && search.isEmpty {
            return "Create a session with +, or choose All workspaces in the header."
        }
        if !session.visibleThreads.isEmpty { return "Try another search or filter." }
        return session.state == .live
            ? "Expose a conversation with /remote-control in desktop Zed, or create a session using +."
            : "Reconnect to refresh your sessions."
    }

    @ViewBuilder private var emptyState: some View {
        if visibleThreads.isEmpty && historyRows.isEmpty && recentThreads.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(emptyTitle).font(.headline)
                Text(emptyDetail).font(.subheadline).foregroundStyle(ZLTheme.muted)
                if session.profile == nil {
                    Button("Open Connections") { session.showConnections = true }
                        .buttonStyle(ZLPrimaryButtonStyle())
                } else if session.state != .live {
                    Button("Reconnect") { Task { await session.refresh() } }
                        .buttonStyle(.bordered).disabled(session.state == .connecting || session.state == .reconnecting)
                } else if session.visibleThreads.isEmpty && session.capabilities.contains("thread.create") {
                    Button("Create Agent session") { showingNewSession = true }
                        .buttonStyle(.bordered)
                } else if session.workspaceFilter != nil {
                    Button("Show all workspaces") { session.setWorkspaceFilter(nil) }
                        .buttonStyle(.bordered)
                }
            }.padding(20)
        }
    }

    private func rows(in group: String) -> [NativeThread] {
        visibleThreads.filter { thread in
            SessionActivity(thread).group == group && !recentThreads.contains { $0.id == thread.id }
        }
    }

    private func pinButton(_ thread: NativeThread) -> some View {
        let pinned: Bool = library.pins.contains(key(thread))
        return Button { library.toggle(key(thread)) } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .foregroundStyle(pinned ? ZLTheme.focus : ZLTheme.muted).frame(width: 44, height: 44)
        }.accessibilityLabel(pinned ? "Unpin session" : "Pin session").accessibilityIdentifier("pin-" + thread.id)
    }

    private var groupedSections: some View {
        ForEach(groups, id: \.self) { group in
            groupSection(group, rows: rows(in: group))
        }
    }

    @ViewBuilder private func groupSection(_ group: String, rows: [NativeThread]) -> some View {
        if !rows.isEmpty {
            HStack { SectionLabel(group); Spacer(); Text("\(rows.count)").font(.caption.monospaced()).foregroundStyle(ZLTheme.muted) }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
            ForEach(rows) { thread in
                HStack(spacing: 0) {
                    sessionLink(thread)
                    pinButton(thread)
                }
                Hairline().padding(.leading, 16)
            }
        }
    }

    @ToolbarContentBuilder private var sessionsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            connectionPicker
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingNewSession = true } label: { Image(systemName: "plus") }
                .disabled(session.state != .live || !session.capabilities.contains("thread.create")).accessibilityLabel("Create Agent session")
                .accessibilityIdentifier("new-agent-session")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await session.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(session.profile == nil).accessibilityLabel("Refresh sessions").accessibilityIdentifier("reconnect")
        }
    }

    /// Top-left: switch between saved connections; also opens projects/history and connection management.
    private var connectionPicker: some View {
        Menu {
            Section("Connections") {
                ForEach(profiles.profiles) { profile in
                    Button { switchConnection(profile) } label: {
                        Label(profile.name + " · " + profile.route.rawValue,
                              systemImage: session.profile?.id == profile.id ? "checkmark" : "desktopcomputer")
                    }
                    .disabled(session.demoPreview)
                }
                if profiles.profiles.isEmpty { Text("No saved connections") }
            }
            if session.supportsWorkspaces {
                Button("Projects & thread history", systemImage: "folder") { showingWorkspaces = true }
                    .disabled(session.state != .live)
                    .accessibilityIdentifier("open-workspaces")
            }
            Button("Manage connections", systemImage: "link") { session.showConnections = true }
        } label: { Image(systemName: "square.stack.3d.up") }
            .accessibilityLabel("Connections")
            .accessibilityIdentifier("connection-picker")
    }

    private func switchConnection(_ profile: ConnectionProfile) {
        guard session.profile?.id != profile.id || session.state != .live else { return }
        profiles.markUsed(profile)
        navigationPath = []
        Task { await session.connect(profile) }
    }

    private var connectionHeader: some View {
        HStack(spacing: 8) {
            WorkspaceBreadcrumbMenu()
            Spacer(minLength: 0)
            if !session.demoPreview { ConnectionStatusView(state: session.state) }
        }.padding(.horizontal, 16).background(ZLTheme.surface)
    }
}

/// A row of "Recent in Zed" / "История": an exposed or saved thread, or a history-only thread.
private struct SessionHistoryRow: Identifiable {
    let id: String
    let date: Date?
    let thread: NativeThread?
    let history: RecentHistoryThread?
}

/// A thread Zed knows from history but has not loaded; tapping loads it in Zed (thread.open).
private struct HistoryThreadRow: View {
    let item: RecentHistoryThread
    let agent: String

    private var meta: String {
        var parts: [String] = [agent]
        if let date = item.thread.updatedAt { parts.append(date.formatted(.relative(presentation: .named))) }
        if !item.thread.loaded { parts.append("Not loaded") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(ZLTheme.muted).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                PlaceBadge(host: item.hostLabel.isEmpty ? item.host : item.hostLabel, workspace: item.project)
                Text(item.thread.title ?? "Untitled thread").font(.body.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(meta).font(.caption).foregroundStyle(ZLTheme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ZLTheme.muted)
        }.padding(.leading, 16).padding(.trailing, 16).padding(.vertical, 14).contentShape(Rectangle())
    }
}

/// New-thread sheet. With `workspace`, the thread is created in that workspace (opening it in
/// Zed first when closed). `onCreated` receives the new thread id before the sheet dismisses.
struct NewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    var workspace: WorkspaceLocation? = nil
    var contextPaths: [String] = []
    var onCreated: ((String) -> Void)? = nil
    @State private var title = ""
    @State private var agentID = "zed-agent"
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                SessionIssueBanner()
                Section("Session") {
                    TextField("Optional title", text: $title)
                    Picker("Agent", selection: $agentID) {
                        ForEach(session.createAgents) { agent in
                            Text("\(agent.name)\(agent.kind == "external_acp" ? " · ACP" : "")").tag(agent.id)
                        }
                    }
                }
                workspaceSection
                Section {
                    Text("The selected agent, model, tools, permissions, and project remain configured in desktop Zed.")
                        .font(.footnote).foregroundStyle(ZLTheme.muted)
                }
            }
            .navigationTitle("New Agent session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") { create() }
                        .disabled(creating || session.creatingThread || session.workspaceProgress != nil || session.createAgents.isEmpty)
                }
            }
            .task {
                await session.loadCreateOptions()
                // The agent used last on this connection and host, not always Zed Agent.
                if let last = session.lastUsedAgent(hostID: workspace?.host.id),
                   session.createAgents.contains(where: { $0.id == last }) {
                    agentID = last
                } else if !session.createAgents.contains(where: { $0.id == agentID }) {
                    agentID = session.createAgents.first?.id ?? "zed-agent"
                }
            }
        }
    }

    @ViewBuilder private var workspaceSection: some View {
        if let workspace {
            Section {
                LabeledContent("Workspace", value: workspace.project.name)
                LabeledContent("Host", value: workspace.host.label)
                if !contextPaths.isEmpty {
                    LabeledContent("Attached", value: contextPaths.joined(separator: ", "))
                }
                if let progress = session.workspaceProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption)
                    }
                } else if !workspace.project.open {
                    Text("This workspace is closed. Zed opens it before creating the session.")
                        .font(.caption).foregroundStyle(ZLTheme.muted)
                }
            }
        }
    }

    private func create() {
        creating = true
        Task {
            let id: String? = await session.createThread(title: title, agentID: agentID, workspace: workspace, contextPaths: contextPaths)
            creating = false
            guard let id else { return }
            onCreated?(id)
            dismiss()
        }
    }
}

private struct SessionRow: View {
    let thread: NativeThread
    let live: Bool
    let updated: Bool
    var host: String? = nil
    var workspace: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var activity: SessionActivity { SessionActivity(thread) }
    private var tint: Color { activity.attention ? ZLTheme.warning : activity.running ? ZLTheme.focus : ZLTheme.muted }
    private var projectLabel: some View {
        PlaceBadge(host: host, workspace: workspace ?? thread.project)
    }
    private var activityLabel: String {
        thread.status == "Saved copy" ? "Saved conversation · not loaded" : activity.running && thread.activity.isWorking ? thread.activity.displayText : activity.rawValue
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.attention ? "exclamationmark.circle" : thread.activity.isCompacting ? "arrow.triangle.2.circlepath" : activity.running ? "waveform" : "bubble.left")
                .symbolEffect(.variableColor, isActive: live && activity.running && !reduceMotion)
                .foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                projectLabel
                Text(thread.title).font(.body.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(thread.agentName + " · " + (live || thread.status == "Saved copy" ? "" : "Last known: ") + activityLabel +
                     (activity == .approval ? " (\(thread.approvalCount ?? 0))" : activity == .input ? " (\(thread.inputCount ?? 0))" : ""))
                    .font(.caption).foregroundStyle(tint)
                if updated { Text("New activity").font(.caption2).foregroundStyle(ZLTheme.focus) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ZLTheme.muted)
        }.padding(.leading, 16).padding(.vertical, 14).contentShape(Rectangle())
    }
}

@MainActor struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var library: SessionLibrary
    @ObservedObject private var composerLibrary = ComposerLibrary.shared
    let threadID: String
    @State private var showingClearConfirmation = false
    @State private var showingCommands = false
    @State private var focusComposerAfterCommand = false
    @State private var pendingCommandReplacement: NativeCommand?
    @State private var showingCommandReplacement = false
    @State private var showingRemoteClipboard = false
    @State private var promptScope: ComposerScope?
    @State private var focusComposerAfterInputSheet = false
    @State private var showingDelegateReplacement = false
    @State private var showingRename = false
    @State private var showingUnexposeConfirmation = false
    @State private var showingContext = false
    @State private var contextInitialTab: WorkspaceTab = .files
    @State private var reviewExpanded = false
    @State private var selectedChildID: String?
    @State private var showingAgentHistory = false
    @State private var lastKnownTitle = ""
    @State private var showingModelControls = false
    @State private var selectedElicitationID: String?
    @State private var showingConversationSearch = false
    @State private var showingAgentErrorDetails = false
    @State private var searchJumpIndex: Int?
    @State private var unreadEntries = 0
    @State private var newActivityWhileReading = false
    @State private var dismissedSlashDraft = ""
    @State private var followsConversation = true
    @State private var scrollHeight: CGFloat = 0
    @State private var pendingReviewVisible = false
    @State private var userScrolling = false
    @State private var followScrollTask: Task<Void, Never>?
    @State private var proposedTitle = ""
    @State private var rewindPoint: NativeRewindPoint?
    @State private var composerPhoto: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var clipboardHasImage = false
    @State private var cachedVisibleCount = 24
    @State private var imageToReview: UIImage?
    @State private var editingAttachmentID: UUID?
    @FocusState private var composerFocused: Bool

    private var composerScope: ComposerScope? {
        guard let profile = session.profile, let targetID = session.targetID else { return nil }
        return ComposerScope(gatewayID: profile.gatewayID, targetID: targetID)
    }

    private var availablePinnedCommands: [NativeCommand] {
        guard let composerScope else { return [] }
        return composerLibrary.pinned(in: composerScope).compactMap { name in
            session.commands.first(where: { $0.name == name })
        }
    }

    var body: some View {
        withDialogs(withInputSheets(withSheets(withAttachmentInputs(withLifecycle(conversationContent)))))
    }

    // `body` is split into these pieces because Swift 6.1 cannot type-check it as one expression in time.
    private var conversationContent: some View {
        VStack(spacing: 0) {
            SessionIssueBanner()
            if let snapshot = session.snapshot, snapshot.threadID == threadID {
                if session.state != .live {
                    let message = session.lastSnapshotAt.map {
                        "Last known conversation · updated \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Last known conversation · update time unknown"
                    savedConversationBanner(message)
                }
                conversation(snapshot)
                    .onAppear { session.markConversationVisible() }
                if session.state == .live, let error = snapshot.agentError {
                    agentErrorBanner(error)
                }
                if session.state == .live && (session.editReview != nil || !session.queuedMessages.isEmpty) { nativeControls }
            } else if let cached = session.cachedConversation(threadID) {
                savedConversationBanner("Saved copy from \(cached.updatedAt.formatted(date: .abbreviated, time: .shortened)). \(cachedConversationDetail)")
                if cached.entries.count > cachedVisibleCount {
                    Button("Show earlier saved messages · \(cached.entries.count - cachedVisibleCount) remaining") {
                        followsConversation = false
                        cachedVisibleCount += 24
                    }
                    .font(.footnote).padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                conversation(cached.displaySnapshot(visibleCount: cachedVisibleCount))
                    .onAppear { session.markConversationVisible() }
            } else {
                unavailableState
            }
        }
    }

    private var isExposed: Bool { session.threads.contains(where: { $0.id == threadID }) }

    private var cachedConversationDetail: String {
        if session.state != .live { return "Reconnect for current state and earlier messages." }
        if session.recoveringThreadID == threadID { return "Opening it in desktop Zed…" }
        return isExposed ? "Loading current state from desktop Zed." : "Desktop Zed has not loaded this thread."
    }

    private var unavailableTitle: String {
        if session.recoveringThreadID == threadID { return "Opening in desktop Zed…" }
        return session.state == .live && !isExposed ? "Session is not loaded" : "Loading native thread"
    }

    private func agentErrorBanner(_ error: NativeAgentError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
            if error.message.count > 240 {
                Text(error.message).font(.footnote).lineLimit(2)
                DisclosureGroup("Full error details", isExpanded: $showingAgentErrorDetails) {
                    ScrollView {
                        Text(error.message).font(.footnote).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(.footnote)
            } else {
                Text(error.message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if error.retrying { Text("Desktop Zed is retrying this request.").font(.footnote) }
        }.foregroundStyle(ZLTheme.warning).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZLTheme.surface).accessibilityIdentifier("native-agent-error")
    }

    private var unavailableState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(unavailableTitle, systemImage: "bubble.left", description: Text("Keep this conversation exposed with /remote-control in desktop Zed. Its contents will reload when it becomes available."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.state != .live { recoveryAction.padding(.bottom, 16) }
            else if isExposed || session.capabilities.contains("thread.open") {
                Button(isExposed ? "Reload conversation" : "Open in desktop Zed") { Task { await session.select(threadID) } }
                    .buttonStyle(.bordered).padding(.bottom, 16)
                    .disabled(session.recoveringThreadID != nil)
            } else { Button("Back to sessions") { dismiss() }.buttonStyle(.bordered).padding(.bottom, 16) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationTaskID: [String] {
        let profileID: String = session.profile?.id.uuidString ?? ""
        let targetID: String = session.targetID ?? ""
        let instanceID: String = session.instanceID ?? ""
        let epoch: String = session.epoch ?? ""
        return [threadID, profileID, targetID, instanceID, epoch, String(session.state == .live), String(isExposed)]
    }

    private func loadConversation() async {
        guard session.state == .live else { return }
        if !session.threads.contains(where: { $0.id == threadID }) {
            // A history or saved thread Zed has not loaded: load it so the conversation goes live.
            guard session.capabilities.contains("thread.open"), await session.recoverThread(threadID) else { return }
        }
        if let profile = session.profile, let targetID = session.targetID {
            let recentKey = SessionLibrary.key(profile: profile.gatewayID, target: targetID, thread: threadID)
            if library.recent.first != recentKey { library.opened(recentKey) }
        }
        lastKnownTitle = session.threads.first { $0.id == threadID }?.title ?? "Agent thread"
        if session.selectedThreadID != threadID || session.snapshot == nil { await session.select(threadID) }
        if let snapshot = session.snapshot, snapshot.threadID == threadID, !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastKnownTitle = snapshot.title }
    }

    private func withLifecycle<Content: View>(_ content: Content) -> some View {
        content
        .background(ZLTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .safeAreaInset(edge: .top, spacing: 0) { conversationHeader }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: conversationTaskID) { await loadConversation() }
        .onChange(of: session.snapshot?.title) { _, title in
            if session.snapshot?.threadID == threadID, let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastKnownTitle = title }
        }
        .onChange(of: session.cachedConversations.count, initial: true) { _, _ in
            if let title = session.cachedConversation(threadID)?.title, lastKnownTitle.isEmpty { lastKnownTitle = title }
        }
        .task(id: composerPhoto) {
            guard let composerPhoto else { return }
            let scope = session.operationScope
            do {
                guard let raw = try await composerPhoto.loadTransferable(type: Data.self),
                      let image = UIImage(data: raw), scope == session.operationScope else { return }
                imageToReview = image
            } catch { if scope == session.operationScope { session.reportIssue("Image unavailable: " + error.localizedDescription) } }
            self.composerPhoto = nil
        }
    }

    private func withAttachmentInputs<Content: View>(_ content: Content) -> some View {
        content
        .photosPicker(isPresented: $showingPhotoPicker, selection: $composerPhoto, matching: .images)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            importPromptFile(result)
        }
        .onAppear { clipboardHasImage = UIPasteboard.general.hasImages }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showingAgentHistory) { SubagentHistoryView() }
        .sheet(isPresented: $showingConversationSearch) {
            ConversationSearchSheet(threadID: threadID) { index in
                followsConversation = false
                searchJumpIndex = index
                showingConversationSearch = false
            }
        }
        .onDisappear { composerFocused = false; followScrollTask?.cancel(); followScrollTask = nil }
        .sheet(isPresented: Binding(get: { selectedChildID != nil }, set: { if !$0 { selectedChildID = nil } })) {
            if let id = selectedChildID { SubagentReader(childID: id) }
        }
        .sheet(isPresented: Binding(get: { imageToReview != nil }, set: { if !$0 { imageToReview = nil; editingAttachmentID = nil } })) {
            if let imageToReview {
                ImageAnnotationView(image: imageToReview, cancel: { self.imageToReview = nil; editingAttachmentID = nil }) { data in
                    if let editingAttachmentID, let index = session.attachments.firstIndex(where: { $0.id == editingAttachmentID }) {
                        session.attachments[index] = PromptAttachment(name: session.attachments[index].name, mimeType: "image/jpeg", data: data)
                    } else { session.addImage(data) }
                    self.imageToReview = nil; editingAttachmentID = nil
                }
            }
        }
        .sheet(isPresented: $showingModelControls) { SessionModelControls() }
        .sheet(isPresented: Binding(get: { selectedElicitationID != nil }, set: { if !$0 { selectedElicitationID = nil } })) {
            NavigationStack {
                ScrollView {
                    if let elicitation = session.elicitations.first(where: { $0.id == selectedElicitationID }) {
                        NativeElicitationView(elicitation: elicitation)
                            .id((session.operationScope + [elicitation.id]).joined(separator: "\n"))
                            .padding(16)
                    } else {
                        ContentUnavailableView("Request completed", systemImage: "checkmark.circle")
                    }
                }
                .background(ZLTheme.background)
                .navigationTitle("Input requested")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { selectedElicitationID = nil } } }
            }
        }
        .confirmationDialog("Run desktop action?", isPresented: Binding(get: { session.localCommandConfirmation != nil }, set: { if !$0 { session.localCommandConfirmation = nil } })) {
            Button("Run /" + (session.localCommandConfirmation?.name ?? "")) { Task { await session.confirmLocalCommand() } }
        } message: { Text(session.localCommandConfirmation?.confirmation ?? "Confirm this desktop action.") }
        .onChange(of: session.localExposureStopped) { _, stopped in if stopped { dismiss() } }
        .sheet(isPresented: $showingContext) { NativeContextSheet(initialTab: contextInitialTab) }
    }

    private func withInputSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showingCommands, onDismiss: {
            if pendingCommandReplacement != nil { showingCommandReplacement = true }
            else if focusComposerAfterCommand { composerFocused = true; focusComposerAfterCommand = false }
        }) {
            SlashCommandPicker(library: composerLibrary, scope: composerScope) { command in
                chooseSlashCommand(command, fromSheet: true)
            }
        }
        .sheet(isPresented: $showingRemoteClipboard, onDismiss: {
            if focusComposerAfterInputSheet { composerFocused = true; focusComposerAfterInputSheet = false }
        }) {
            RemoteClipboardView(destination: "prompt") { text in
                if appendToDraft(text) { focusComposerAfterInputSheet = true }
            }
        }
        .sheet(item: $promptScope, onDismiss: {
            if focusComposerAfterInputSheet { composerFocused = true; focusComposerAfterInputSheet = false }
        }) { scope in
            PromptSnippetsView(library: composerLibrary, scope: scope, currentDraft: session.draft) { text in
                guard scope == composerScope else {
                    session.reportIssue("The Zed workspace changed. Open Saved prompts again.")
                    return false
                }
                let inserted = appendToDraft(text)
                if inserted { focusComposerAfterInputSheet = true }
                return inserted
            }
        }
        .onChange(of: composerScope) { _, scope in
            if promptScope != scope { promptScope = nil }
            showingCommands = false
            pendingCommandReplacement = nil
            showingCommandReplacement = false
            focusComposerAfterCommand = false
            focusComposerAfterInputSheet = false
        }
    }

    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
        .confirmationDialog("Clear uncertain delivery?", isPresented: $showingClearConfirmation) {
            Button("Clear locally", role: .destructive) { session.clearPending() }
        } message: {
            Text("Inspect the desktop transcript first. Clearing this record does not cancel a native turn.")
        }
        .confirmationDialog("Replace your draft?", isPresented: $showingDelegateReplacement) {
            Button("Replace with delegated task draft", role: .destructive) {
                session.prepareSubagentTask(); composerFocused = true
            }
        } message: {
            Text("Your current message has not been sent. Replacing it will discard that draft.")
        }
        .confirmationDialog("Replace your draft with a slash command?", isPresented: $showingCommandReplacement) {
            if let command = pendingCommandReplacement {
                Button("Use /\(command.name)", role: .destructive) {
                    session.insertCommand(command)
                    dismissedSlashDraft = session.draft
                    if let composerScope { composerLibrary.recordChoice(command.name, in: composerScope) }
                    pendingCommandReplacement = nil
                    composerFocused = true
                }
            }
        } message: {
            Text("Your current message has not been sent. Choosing a slash command will replace that draft.")
        }
        .onChange(of: showingCommandReplacement) { _, isPresented in
            if !isPresented { pendingCommandReplacement = nil }
        }
        .alert("Rename session", isPresented: $showingRename) {
            TextField("Session title", text: $proposedTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { _ = await session.renameSelectedThread(to: proposedTitle) } }
                .disabled(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("The title also changes in desktop Zed.") }
        .confirmationDialog("Stop exposing this session?", isPresented: $showingUnexposeConfirmation) {
            Button("Stop exposing", role: .destructive) {
                Task { if await session.unexposeSelectedThread() { dismiss() } }
            }
        } message: { Text("The Agent keeps running in desktop Zed. Remote access to this session stops.") }
        .confirmationDialog("Rewind this conversation?", isPresented: Binding(
            get: { rewindPoint != nil }, set: { if !$0 { rewindPoint = nil } }
        )) {
            Button("Rewind", role: .destructive) {
                if let point = rewindPoint { Task { await session.rewind(to: point) } }
                rewindPoint = nil
            }
        } message: { Text("Messages and Agent edits after this point may be removed.") }
    }

    private func savedConversationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(ZLTheme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.state != .live && session.issue.isEmpty {
                Button {
                    if session.profile == nil { session.showConnections = true }
                    else { Task { await session.refresh() } }
                } label: {
                    Image(systemName: session.profile == nil ? "network" : "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .disabled(session.profile != nil && (session.state == .connecting || session.state == .reconnecting))
                .accessibilityLabel(session.profile == nil ? "Choose connection" : "Reconnect to desktop Zed")
                .accessibilityIdentifier("conversation-reconnect")
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("saved-conversation-banner")
    }

    private var recoveryAction: some View {
        Group {
            if session.profile == nil {
                Button("Choose connection") { session.showConnections = true }
            } else {
                Button("Reconnect to desktop Zed") { Task { await session.refresh() } }
                    .disabled(session.state == .connecting || session.state == .reconnecting)
            }
        }.buttonStyle(.bordered).frame(minHeight: 44)
            .accessibilityIdentifier("conversation-reconnect")
    }

    private var conversationHeader: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    backButton
                    headerTitle.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    changesButton
                    workspaceButton
                    headerActions
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        backButton
                        Spacer(minLength: 0)
                        changesButton
                        workspaceButton
                        headerActions
                    }
                    headerTitle.padding(.horizontal, 12).padding(.bottom, 8)
                }
            }.padding(.horizontal, 8).padding(.vertical, 4).buttonStyle(.plain)
            Hairline()
        }.background(ZLTheme.background).foregroundStyle(ZLTheme.ink)
    }

    private var backButton: some View {
        Button { composerFocused = false; dismiss() } label: {
            Image(systemName: "arrow.left").frame(width: 44, height: 44)
        }.accessibilityLabel("Back to sessions").accessibilityIdentifier("back-to-sessions")
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lastKnownTitle.isEmpty ? "Agent thread" : lastKnownTitle)
                .font(.headline).lineLimit(2)
            if let place = session.placeLabel(for: threadID) {
                Text(place).font(.caption).foregroundStyle(ZLTheme.muted).lineLimit(1)
                    .accessibilityIdentifier("conversation-place")
            }
            if session.state != .live { ConnectionStatusView(state: session.state) }
            if session.state == .live && !session.controlsIssue.isEmpty {
                Button { Task { await session.refreshSessionControls() } } label: {
                    Label("Retry · \(session.controlsIssue)", systemImage: "arrow.clockwise")
                        .font(.caption2).foregroundStyle(ZLTheme.muted).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityHint("Retries loading approvals, queue and agent settings; the conversation is live")
            }
            if let snapshot = session.snapshot, snapshot.threadID == threadID, snapshot.isBusy {
                agentProgress
            }
            if let settings = session.threadSettings, session.selectedThreadID == threadID,
               let used = settings.usedTokens, let maximum = settings.maxTokens, maximum > 0 {
                Button { showingModelControls = true } label: {
                    HStack(spacing: 8) {
                        Label("\(used.formatted()) / \(maximum.formatted())", systemImage: "circle.lefthalf.filled")
                        if let input = settings.inputTokens {
                            Label(input.formatted(), systemImage: "arrow.down")
                        }
                        if let output = settings.outputTokens {
                            Label(output.formatted(), systemImage: "arrow.up")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Double(used) / Double(maximum) >= 0.8 ? ZLTheme.warning : ZLTheme.muted)
                    .lineLimit(1)
                }
                .accessibilityLabel("Context used \(used) of \(maximum) tokens. Input \(settings.inputTokens ?? 0), output \(settings.outputTokens ?? 0). Open Agent settings")
                .accessibilityIdentifier("context-usage")
            }
        }.accessibilityIdentifier("conversation-title")
    }

    private var workspaceButton: some View {
        Button { composerFocused = false; contextInitialTab = .files; showingContext = true } label: {
            Image(systemName: "square.grid.2x2").frame(width: 44, height: 44)
        }.accessibilityLabel("Workspace").accessibilityIdentifier("open-workspace")
    }

    private var changesButton: some View {
        Button { composerFocused = false; contextInitialTab = .changes; showingContext = true } label: {
            Image(systemName: "square.stack.3d.up").frame(width: 44, height: 44)
        }.accessibilityLabel("Project changes").accessibilityIdentifier("open-changes")
    }

    private var headerActions: some View {
        Menu {
            Text("Connection: \(session.state.label)")
            if session.state == .live && !session.controlsIssue.isEmpty {
                Text("Some session controls didn't load (\(session.controlsIssue)). The conversation is live.")
                Button("Retry session controls", systemImage: "arrow.clockwise") {
                    Task { await session.refreshSessionControls() }
                }
            }
            Button("Find in conversation", systemImage: "magnifyingglass") { showingConversationSearch = true }
            if !session.delivery.isEmpty { Menu("Recent delivery status") { Text(session.delivery) } }
            Button("Reconnect and refresh", systemImage: "arrow.clockwise") {
                Task { await session.refresh() }
            }.disabled(session.profile == nil)
            Button("Agent history", systemImage: "person.2") { composerFocused = false; showingAgentHistory = true }
            Button("Agent settings", systemImage: "slider.horizontal.3") { composerFocused = false; showingModelControls = true }
            Button("New session", systemImage: "plus.bubble") {
                composerFocused = false
                Task { await session.createSiblingThread(of: threadID) }
            }.disabled(session.state != .live || !session.capabilities.contains("thread.create") || session.creatingThread || session.workspaceProgress != nil || !isExposed)
                .accessibilityIdentifier("new-sibling-session")
            Button("Draft delegated task", systemImage: "arrow.triangle.branch") {
                if session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    session.prepareSubagentTask(); composerFocused = true
                }
                else { showingDelegateReplacement = true }
            }.disabled(session.state != .live)
                .accessibilityIdentifier("delegate-subagent-task")
            Button("Rename session", systemImage: "pencil") {
                proposedTitle = session.snapshot?.title ?? ""; showingRename = true
            }.disabled(!session.capabilities.contains("thread.rename"))
            Button("Stop exposing", systemImage: "eye.slash", role: .destructive) { showingUnexposeConfirmation = true }
                .disabled(!session.capabilities.contains("thread.unexpose"))
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Session actions")
    }

    private func conversation(_ snapshot: ThreadSnapshot) -> some View {
        let live = session.state == .live && session.snapshot?.threadID == snapshot.threadID
        let linkedCalls = Set(snapshot.entryMeta.compactMap { $0?.callID })
        let linkedQuestions = Set(snapshot.entryMeta.compactMap { $0?.elicitationID })
        let fallbackApprovals = live ? snapshot.pendingApprovals.filter { $0.subagentID != nil || !linkedCalls.contains($0.id) } : []
        let fallbackQuestions = live ? session.elicitations.filter { !linkedQuestions.contains($0.id) } : []
        var matchingReviewIndex: Int? = nil
        if let approval = snapshot.pendingApprovals.first, approval.subagentID == nil {
            matchingReviewIndex = snapshot.entryMeta.firstIndex { $0?.callID == approval.id }
        } else if snapshot.pendingApprovals.isEmpty, let question = session.elicitations.first {
            matchingReviewIndex = snapshot.entryMeta.firstIndex { $0?.elicitationID == question.id }
        }
        let reviewIndex = live ? matchingReviewIndex.map { snapshot.entryStartIndex + $0 } : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if snapshot.entries.isEmpty {
                        ContentUnavailableView(snapshot.totalEntries == 0 ? "No messages yet" : "Conversation is loading", systemImage: "bubble.left", description: Text(snapshot.totalEntries == 0 ? "Send a message to begin this native Zed session." : "The latest messages will appear here when desktop Zed returns them."))
                            .frame(maxWidth: .infinity, minHeight: 260)
                            .accessibilityIdentifier("conversation-empty-state")
                    }
                    let activeChildren = snapshot.subagents.filter { child in child.isActive || snapshot.pendingApprovals.contains { $0.subagentID == child.id } }
                    if !activeChildren.isEmpty {
                        Text("PARALLEL AGENTS · \(snapshot.subagents.filter(\.isActive).count) ACTIVE")
                            .font(.caption.monospaced()).foregroundStyle(ZLTheme.muted).padding(.horizontal, 16).padding(.top, 8)
                        ForEach(activeChildren) { child in
                            let needsApproval = snapshot.pendingApprovals.contains { $0.subagentID == child.id }
                            Button { composerFocused = false; selectedChildID = child.id } label: {
                                HStack(spacing: 10) {
                                    if needsApproval { Image(systemName: "hand.raised").foregroundStyle(ZLTheme.warning) }
                                    else if child.isActive { ProgressView().controlSize(.small) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(child.title).font(.subheadline).lineLimit(2)
                                        Text("\(needsApproval ? "Approval needed" : child.status) · \(child.totalEntries > 0 ? child.totalEntries : child.entries.count) entries").font(.caption).foregroundStyle(ZLTheme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                }.padding(.horizontal, 16).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                            Hairline()
                        }
                    }
                    if snapshot.hasOlderEntries && session.state == .live && session.snapshot?.threadID == snapshot.threadID {
                        Button("Load earlier conversation · \(snapshot.entryStartIndex) remaining") {
                            followsConversation = false
                            Task { await session.loadEarlierHistory() }
                        }
                        .font(.footnote).foregroundStyle(ZLTheme.muted)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    ForEach(snapshot.entryStartIndex..<(snapshot.entryStartIndex + snapshot.entries.count), id: \.self) { entryIndex in
                        transcriptRow(snapshot, index: entryIndex, live: live)
                            .id(entryIndex)
                            .background { if entryIndex == reviewIndex { reviewPosition } }
                        Hairline().padding(.horizontal, 14)
                    }
                    if !fallbackApprovals.isEmpty {
                        approvalStack(fallbackApprovals).id("pending-review")
                            .background { if reviewIndex == nil { reviewPosition } }
                    }
                    if !fallbackQuestions.isEmpty {
                        elicitationStack(fallbackQuestions).id("pending-input")
                            .background { if reviewIndex == nil && fallbackApprovals.isEmpty { reviewPosition } }
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ConversationScrollMetrics.self, value: ["bottom": geometry.frame(in: .named("conversation-scroll")).maxY])
                        })
                }
            }
            .coordinateSpace(name: "conversation-scroll")
            .background(GeometryReader { geometry in Color.clear.preference(key: ConversationScrollMetrics.self, value: ["height": geometry.size.height]) })
            .onPreferenceChange(ConversationScrollMetrics.self) { metrics in
                if let height = metrics["height"] { scrollHeight = height }
                if let top = metrics["reviewTop"], let bottom = metrics["reviewBottom"], scrollHeight > 0 {
                    pendingReviewVisible = min(bottom, scrollHeight) - max(top, 0) >= 44
                } else { pendingReviewVisible = false }
                if userScrolling, let bottom = metrics["bottom"], scrollHeight > 0 {
                    followsConversation = bottom >= 0 && bottom <= scrollHeight + 50
                    if followsConversation { unreadEntries = 0; newActivityWhileReading = false }
                }
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolling = true; followsConversation = false }.onEnded { _ in userScrolling = false })
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if live && !pendingReviewVisible && (reviewIndex != nil || !fallbackApprovals.isEmpty || !fallbackQuestions.isEmpty) {
                    Button {
                        composerFocused = false
                        if let reviewIndex { proxy.scrollTo(reviewIndex, anchor: .center) }
                        else { proxy.scrollTo(fallbackApprovals.isEmpty ? "pending-input" : "pending-review", anchor: .center) }
                    } label: {
                        Label("Review pending action", systemImage: "hand.raised")
                            .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).background(ZLTheme.warning.opacity(0.1))
                }
                if !followsConversation {
                    HStack {
                        Spacer()
                        Button {
                            followScrollTask?.cancel()
                            followsConversation = true; unreadEntries = 0; newActivityWhileReading = false
                            dismissZedLinkKeyboard()
                            proxy.scrollTo("conversation-bottom", anchor: .bottom)
                        } label: {
                            Label(unreadEntries > 0 ? "Latest · \(unreadEntries) new" : newActivityWhileReading ? "Latest · new activity" : "Latest", systemImage: "arrow.down")
                                .font(.caption).frame(minHeight: 44)
                        }
                            .buttonStyle(.plain).accessibilityIdentifier("jump-to-latest")
                            .accessibilityHint("Scrolls to the newest Agent message")
                    }.padding(.horizontal, 16).background(ZLTheme.background)
                        .overlay(alignment: .top) { Hairline() }
                }
            }
            .task(id: [snapshot.instanceID, snapshot.epoch, snapshot.threadID]) {
                followsConversation = true
                unreadEntries = 0; newActivityWhileReading = false
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, !snapshot.entries.isEmpty else { return }
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: snapshot.totalEntries) { old, new in
                if !followsConversation { unreadEntries += max(0, new - old) }
            }
            .onChange(of: snapshot.entries.last) { _, _ in
                guard followsConversation else { newActivityWhileReading = true; return }
                followScrollTask?.cancel()
                followScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled, followsConversation else { return }
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: searchJumpIndex) { _, index in
                guard let index else { return }
                proxy.scrollTo(index, anchor: .center)
                searchJumpIndex = nil
            }
        }
    }

    private var reviewPosition: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ConversationScrollMetrics.self, value: [
                "reviewTop": geometry.frame(in: .named("conversation-scroll")).minY,
                "reviewBottom": geometry.frame(in: .named("conversation-scroll")).maxY,
            ])
        }
    }

    private func transcriptRow(_ snapshot: ThreadSnapshot, index: Int, live: Bool) -> some View {
        let offset = index - snapshot.entryStartIndex
        let meta = snapshot.entryMeta.indices.contains(offset) ? snapshot.entryMeta[offset] : nil
        let question = live ? session.elicitations.first { $0.id == meta?.elicitationID } : nil
        return VStack(alignment: .leading, spacing: 0) {
            if question == nil {
                NativeEntryView(markdown: snapshot.entries[offset], index: index,
                                thinkingLive: snapshot.isBusy && index == snapshot.totalEntries - 1)
                    .equatable()
            }
            if let question { elicitationRow(question) }
            if live, let approval = snapshot.pendingApprovals.first(where: { $0.subagentID == nil && $0.id == meta?.callID }) {
                NativeApprovalView(approval: approval).padding(12)
            }
            if live, !snapshot.isBusy, session.capabilities.contains("thread.rewind"),
               let point = snapshot.rewindPoints.first(where: { $0.entryIndex == index }) {
                Button("Rewind conversation here", role: .destructive) { rewindPoint = point }
                    .font(.caption).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private func approvalStack(_ approvals: [NativeApproval]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if approvals.count == 1 {
                NativeApprovalView(approval: approvals[0])
                    .padding(.horizontal, 12).padding(.vertical, 9)
            } else {
                Text("\(approvals.count) requests need your decision")
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 16).padding(.top, 9)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(approvals, id: \.viewIdentity) { NativeApprovalView(approval: $0) }
                    }.padding(.horizontal, 12).padding(.vertical, 9)
                }.frame(maxHeight: 320)
            }
        }
        .background(ZLTheme.background)
        .overlay(alignment: .top) { Hairline() }
    }

    private func elicitationStack(_ elicitations: [NativeElicitation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if elicitations.count > 2 {
                Text("\(elicitations.count) input requests")
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 16).padding(.top, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(elicitations) { elicitation in elicitationRow(elicitation) }
                    }
                }.frame(maxHeight: 180)
            } else {
                ForEach(elicitations) { elicitation in elicitationRow(elicitation) }
            }
        }
        .background(ZLTheme.warning.opacity(0.07))
        .overlay(alignment: .top) { Hairline() }
    }

    private func elicitationRow(_ elicitation: NativeElicitation) -> some View {
        VStack(spacing: 0) {
            Button { composerFocused = false; selectedElicitationID = elicitation.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(ZLTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Input requested").font(.footnote.weight(.semibold))
                        Text(elicitation.message).font(.footnote).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("input-request-" + elicitation.id)
            Hairline()
        }
    }

    private var nativeControls: some View {
        VStack(spacing: 8) {
            if let review = session.editReview {
                DisclosureGroup(isExpanded: $reviewExpanded) {
                    HStack {
                    VStack(alignment: .leading) {
                        Text("Review Agent edits").font(.subheadline.weight(.semibold))
                        Text("\(review.changedFiles) \(review.changedFiles == 1 ? "file" : "files") · +\(review.linesAdded) −\(review.linesRemoved)")
                            .font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                    }
                    Spacer()
                    Button("Reject all", role: .destructive) { Task { await session.resolveEditReview("reject_all") } }
                    Button("Keep all") { Task { await session.resolveEditReview("keep_all") } }
                    }.disabled(session.state != .live)
                } label: {
                    Label("Edits · \(review.changedFiles) \(review.changedFiles == 1 ? "file" : "files") · +\(review.linesAdded) −\(review.linesRemoved)", systemImage: "square.and.pencil")
                        .font(.footnote).frame(minHeight: 44, alignment: .leading)
                }
            }
            if !session.queuedMessages.isEmpty {
                HStack {
                    Text("\(session.queuedMessages.count) queued message\(session.queuedMessages.count == 1 ? "" : "s")")
                    Spacer()
                    Button("Clear queue", role: .destructive) { Task { await session.clearQueue() } }
                }.font(.footnote)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(ZLTheme.surface).overlay(alignment: .top) { Hairline() }
        .disabled(session.state != .live)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.state == .live, session.selectedThreadID == threadID,
               let settings = session.threadSettings {
                let agent = session.threads.first { $0.id == threadID }?.agentName ?? "Zed Agent"
                let selectedModel = settings.models.first { $0.id == "\(settings.providerID ?? "")\n\(settings.modelID ?? "")" }?.name ?? settings.modelID
                let model: String? = selectedModel ?? (settings.managedByAgent ? "Managed by the agent" : nil)
                Button { showingModelControls = true } label: {
                    Label(agent + (model.map { " · \($0)" } ?? ""), systemImage: "slider.horizontal.3")
                        .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("Agent settings: " + agent + (model.map { ", model \($0)" } ?? ""))
                    .padding(.horizontal, 12)
            }
            if !session.uploads.isEmpty { uploadChips }
            if !session.attachments.isEmpty || !session.contextPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.attachments) { image in
                            Menu {
                                if image.isImage {
                                    Button("Annotate") { editingAttachmentID = image.id; imageToReview = UIImage(data: image.data) }
                                }
                                Button("Remove", role: .destructive) { session.attachments.removeAll { $0.id == image.id } }
                            } label: { Label(image.name, systemImage: image.isImage ? "photo" : "doc.text") }
                        }
                        ForEach(Array(session.contextPaths).sorted(), id: \.self) { path in
                            Button { session.contextPaths.remove(path) } label: { Label(path, systemImage: "xmark.circle") }
                        }
                    }.font(.caption).padding(4)
                }.accessibilityIdentifier("prompt-attachments")
            }
            if !session.delivery.isEmpty && (session.pending != nil || session.state != .live) {
                Text(session.delivery).font(.caption).foregroundStyle(ZLTheme.muted)
                    .lineLimit(2).accessibilityIdentifier("delivery-status")
            }
            if session.pending != nil { uncertainDelivery }
            if session.draft.hasPrefix("/"), session.draft != dismissedSlashDraft, !session.draft.contains(where: { $0.isWhitespace }) {
                NativeSlashSuggestions(commands: session.commands, query: String(session.draft.dropFirst())) { command in
                    session.insertCommand(command); dismissedSlashDraft = session.draft
                    if let composerScope { composerLibrary.recordChoice(command.name, in: composerScope) }
                }.task { await session.refreshCommands() }
            }
            clipboardImageRow
            VStack(alignment: .leading, spacing: 0) {
                composerTextField.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Menu {
                        Section("Add to message") {
                            // A PhotosPicker inside a Menu never presents; the menu item raises a flag instead.
                            Button("Add image", systemImage: "photo.badge.plus") {
                                composerFocused = false; showingPhotoPicker = true
                            }
                            .disabled(!canAttachFiles || session.supportsImages == false)
                            .accessibilityIdentifier("composer-add-image")
                            Button("Paste image from phone", systemImage: "doc.on.clipboard") { pasteImageFromPhone() }
                            .disabled(!canAttachFiles || session.supportsImages == false)
                            Button(session.supportsUploads ? "File… (up to 25 MiB)" : "File…", systemImage: "doc.badge.plus") {
                                composerFocused = false; showingFileImporter = true
                            }
                            .disabled(!canAttachFiles)
                            .accessibilityIdentifier("composer-add-file")
                            Button("Paste text from phone", systemImage: "text.alignleft") {
                                _ = appendToDraft(UIPasteboard.general.string ?? "")
                            }
                            .accessibilityIdentifier("paste-phone-text")
                            Button("Paste text from desktop", systemImage: "doc.on.doc") {
                                composerFocused = false; showingRemoteClipboard = true
                            }
                            Button("Project context", systemImage: "folder.badge.plus") {
                                composerFocused = false; contextInitialTab = .files; showingContext = true
                            }
                        }
                        Section("Draft tools") {
                            Button("Slash commands", systemImage: "terminal") {
                                composerFocused = false; showingCommands = true
                            }
                            Button("Saved prompts", systemImage: "bookmark") {
                                composerFocused = false; promptScope = composerScope
                            }
                            .disabled(composerScope == nil)
                            .accessibilityIdentifier("saved-prompts")
                        }
                        if !availablePinnedCommands.isEmpty {
                            Section("Pinned commands") {
                                ForEach(availablePinnedCommands.prefix(4)) { command in
                                    Button("/\(command.name)", systemImage: "pin") {
                                        chooseSlashCommand(command, fromSheet: false)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Add to message or choose a slash command")
                    .accessibilityIdentifier("composer-add")
                    VoiceDraftButton(text: $session.draft, scope: "\(session.profile?.id.uuidString ?? "").\(session.targetID ?? "").\(session.instanceID ?? "").\(session.epoch ?? "").\(session.selectedThreadID ?? "")")
                    Spacer(minLength: 0)
                    sendOrStopButton
                }.padding(.horizontal, 4)
            }
            .padding(4)
            .background(ZLTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ZLTheme.line, lineWidth: 1))
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
        .background(ZLTheme.background)
        .overlay(alignment: .top) { Hairline() }
    }

    /// "📎 name" chips for files uploaded into the project: progress while uploading, tap to remove.
    private var uploadChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.uploads) { upload in uploadChip(upload) }
                }.padding(.horizontal, 4)
            }
            if let failure = session.uploads.compactMap(\.failure).last {
                Text(failure).font(.caption2).foregroundStyle(ZLTheme.warning).lineLimit(2).padding(.horizontal, 8)
            }
        }
        .accessibilityIdentifier("prompt-uploads")
    }

    private func uploadChip(_ upload: ComposerUpload) -> some View {
        Button { session.removeUpload(upload.id) } label: {
            HStack(spacing: 6) {
                Text("📎 " + upload.name).lineLimit(1).truncationMode(.middle)
                if upload.isUploading {
                    ProgressView(value: upload.progress).frame(width: 36)
                } else if upload.failure != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ZLTheme.warning)
                }
                Image(systemName: "xmark.circle.fill").foregroundStyle(ZLTheme.muted)
            }
            .font(.caption).padding(.horizontal, 10).frame(minHeight: 32)
            .background(ZLTheme.raised, in: Capsule())
            .frame(maxWidth: 240)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(uploadAccessibilityLabel(upload))
        .accessibilityHint("Removes this file from the message")
    }

    private func uploadAccessibilityLabel(_ upload: ComposerUpload) -> String {
        if let failure = upload.failure { return "\(upload.name), upload failed: \(failure)" }
        if upload.isUploading { return "\(upload.name), uploading \(Int(upload.progress * 100)) percent" }
        return "\(upload.name), attached"
    }

    /// System paste control, shown while the phone clipboard holds an image. It pastes without the
    /// "Allow Paste" prompt because the user taps the system button directly.
    @ViewBuilder private var clipboardImageRow: some View {
        if clipboardHasImage && canAttachFiles && session.supportsImages != false
            && session.state == .live && session.selectedThreadID == threadID {
            HStack(spacing: 8) {
                Label("Image on clipboard", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(ZLTheme.muted)
                Spacer(minLength: 0)
                PasteButton(supportedContentTypes: [.image]) { providers in
                    Task { @MainActor in
                        if let image = await loadPromptImage(from: providers) { imageToReview = image }
                        else { session.reportIssue("Clipboard does not contain a supported image.") }
                    }
                }
                .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.small)
                Button { clipboardHasImage = false } label: {
                    Image(systemName: "xmark").font(.caption).frame(width: 32, height: 32)
                }.buttonStyle(.plain).accessibilityLabel("Hide clipboard image suggestion")
            }.padding(.horizontal, 12)
        }
    }

    private func pasteImageFromPhone() {
        let scope = session.operationScope
        Task { @MainActor in
            let image: UIImage? = await loadPhoneClipboardImage()
            guard scope == session.operationScope else { return }
            if let image { imageToReview = image }
            else { session.reportIssue("Clipboard does not contain a supported image (PNG, JPEG, HEIC or WebP).") }
        }
    }

    /// Text, attachments or finished uploads, and no upload still running.
    private var hasSendableContent: Bool {
        if session.uploads.contains(where: { $0.isUploading }) { return false }
        let hasText: Bool = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUploads: Bool = session.uploads.contains(where: { $0.ref != nil })
        return hasText || !session.attachments.isEmpty || !session.contextPaths.isEmpty || hasUploads
    }

    /// New bridges take any file into the project (project.upload.*); older ones take small attachments.
    private var canAttachFiles: Bool {
        session.supportsUploads || session.capabilities.contains("thread.attachments")
    }

    private func importPromptFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            session.reportIssue("File unavailable: " + error.localizedDescription)
        case .success(let url) where session.supportsUploads:
            switch readUploadFile(url) {
            case .success(let file): session.addUpload(fileName: file.name, mimeType: file.mimeType, data: file.data)
            case .failure(let message): session.reportIssue(message)
            }
        case .success(let url):
            switch readPromptFile(url) {
            case .image(let image): imageToReview = image
            case .text(let name, let mimeType, let data): session.addTextFile(name: name, mimeType: mimeType, data: data)
            case .failure(let message): session.reportIssue(message)
            }
        }
    }

    private var composerTextField: some View {
        TextField("Message Zed Agent…", text: $session.draft, axis: .vertical)
            .lineLimit(1...8).padding(.horizontal, 11).padding(.top, 6).padding(.bottom, 2)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit { sendAndDismissKeyboard() }
            .accessibilityLabel("Message to native Zed Agent")
            .accessibilityIdentifier("composer")
    }

    private var sendOrStopButton: some View {
        Group {
            if session.canCancel {
                Button { composerFocused = false; Task { await session.cancelCurrentTurn() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ZLTheme.danger)
                        .frame(width: 32, height: 32)
                        .background(ZLTheme.danger.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Stop current turn").accessibilityIdentifier("stop-current-turn")
            } else {
                Button { sendAndDismissKeyboard() } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44)
                }.foregroundStyle(ZLTheme.background).background(ZLTheme.ink).clipShape(Circle())
                    .disabled(!session.canSend || !hasSendableContent)
                    .accessibilityLabel("Send").accessibilityIdentifier("send-prompt")
            }
        }
    }

    private var agentProgress: some View {
        HStack(spacing: 5) {
            Image(systemName: session.state != .live ? "pause.circle" : session.liveActivity.isCompacting ? "arrow.triangle.2.circlepath" : "waveform")
                .foregroundStyle(session.state == .live ? ZLTheme.focus : ZLTheme.warning)
            Text(session.state == .live ? session.liveActivity.displayText : "Last known: " + session.liveActivity.displayText)
                .foregroundStyle(ZLTheme.muted).lineLimit(1)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-working-indicator")
    }

    private func sendAndDismissKeyboard() {
        guard session.canSend, hasSendableContent else { return }
        composerFocused = false
        Task { await session.send() }
    }

    @discardableResult private func appendToDraft(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.reportIssue("No text is available to paste into this message.")
            return false
        }
        let separator = session.draft.isEmpty ? "" : "\n"
        guard (session.draft + separator + text).utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: {
                  ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127
              }) else {
            session.reportIssue("Use plain text up to 16 KiB without control characters.")
            return false
        }
        let current = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.commands.contains(where: { $0.execution == "local" && current == "/" + $0.name }) else {
            session.reportIssue("Run the local slash command separately before adding prompt text.")
            return false
        }
        session.draft += separator + text
        composerFocused = true
        return true
    }

    private func chooseSlashCommand(_ command: NativeCommand, fromSheet: Bool) {
        guard let composerScope,
              session.commands.contains(where: { $0.name == command.name }) else {
            session.reportIssue("This command is no longer available in the selected Zed thread.")
            return
        }
        let current = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current.hasPrefix("/") && !current.contains(where: \.isWhitespace) {
            session.insertCommand(command)
            dismissedSlashDraft = session.draft
            composerLibrary.recordChoice(command.name, in: composerScope)
            if fromSheet { focusComposerAfterCommand = true }
            else { composerFocused = true }
        } else {
            pendingCommandReplacement = command
            if !fromSheet { showingCommandReplacement = true }
        }
    }

    private var uncertainDelivery: some View {
        HStack(spacing: 14) {
            Text("Delivery needs review").font(.caption.monospaced()).foregroundStyle(ZLTheme.warning)
            Spacer()
            Button("Check") { Task { await session.reconcilePending() } }
                .accessibilityIdentifier("check-request-status")
            if session.pending?.text != nil {
                Button("Retry") { Task { await session.retryPending() } }
                    .accessibilityIdentifier("retry-same-request")
            }
            Button("Clear") { showingClearConfirmation = true }
        }
        .font(.caption)
    }
}

private struct ConversationSearchSheet: View {
    @EnvironmentObject private var session: SessionManager
    let threadID: String
    let onSelect: (Int) -> Void
    @State private var query = ""
    @State private var loadingHistory = false

    private var snapshot: ThreadSnapshot? {
        if let snapshot = session.snapshot, snapshot.threadID == threadID { return snapshot }
        return session.cachedConversation(threadID)?.displaySnapshot(visibleCount: 128)
    }

    private var matches: [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot, needle.count >= 2 else { return [] }
        return Array(snapshot.entries.indices.filter {
            snapshot.entries[$0].localizedCaseInsensitiveContains(needle)
        }.prefix(100))
    }

    var body: some View {
        NavigationStack {
            List {
                if let snapshot {
                    Section {
                        Text("Searching messages \(snapshot.entries.isEmpty ? 0 : snapshot.entryStartIndex + 1)–\(snapshot.entryStartIndex + snapshot.entries.count) of \(snapshot.totalEntries). \(snapshot.hasOlderEntries ? "Load earlier messages below." : "All messages are loaded.")")
                            .font(.footnote).foregroundStyle(ZLTheme.muted)
                    }
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                        Text("Enter at least two characters to search loaded messages.")
                            .foregroundStyle(ZLTheme.muted)
                    } else if matches.isEmpty {
                        ContentUnavailableView("No matches in loaded messages", systemImage: "magnifyingglass")
                    } else {
                        ForEach(matches, id: \.self) { offset in
                            Button {
                                onSelect(snapshot.entryStartIndex + offset)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Message \(snapshot.entryStartIndex + offset + 1)")
                                        .font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                                    Text(snapshot.entries[offset]).lineLimit(3)
                                        .foregroundStyle(ZLTheme.ink)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.accessibilityIdentifier("conversation-search-result-\(snapshot.entryStartIndex + offset)")
                        }
                    }
                    if snapshot.hasOlderEntries && session.state == .live && session.selectedThreadID == threadID {
                        Button {
                            loadingHistory = true
                            Task {
                                await session.loadEarlierHistory()
                                loadingHistory = false
                            }
                        } label: {
                            if loadingHistory { ProgressView("Loading earlier messages…") }
                            else { Label("Load earlier messages", systemImage: "arrow.up.doc") }
                        }.disabled(loadingHistory).accessibilityIdentifier("search-earlier-messages")
                    }
                } else {
                    ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left")
                }
            }
            .searchable(text: $query, prompt: "Search messages")
            .navigationTitle("Find in conversation")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("conversation-search")
        }
    }
}

private enum WorkspaceTab: String, CaseIterable, Identifiable {
    case files = "Files", changes = "Changes", terminal = "Terminal", debug = "Debug", activity = "Activity"
    var id: String { rawValue }
}

private struct NativeContextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @State private var tab: WorkspaceTab
    @State private var activityExpanded = true
    @State private var selectedDiffLine: Int? = nil

    init(initialTab: WorkspaceTab = .files) { _tab = State(initialValue: initialTab) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SessionIssueBanner()
                if session.workspaceLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading workspace") }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(WorkspaceTab.allCases) { item in
                            Button {
                                dismissZedLinkKeyboard()
                                tab = item
                            } label: {
                                Text(item.rawValue).font(.caption.weight(tab == item ? .semibold : .regular))
                                    .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                                    .overlay(alignment: .bottom) {
                                        if tab == item { Rectangle().fill(ZLTheme.ink).frame(height: 2) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(tab == item ? .isSelected : [])
                            .accessibilityIdentifier("workspace-" + item.rawValue.lowercased())
                        }
                    }.padding(.horizontal, 8)
                }
                Hairline()
                Group {
                    switch tab {
                    case .files:
                        if session.capabilities.contains("project.files") {
                            ProjectFileBrowser()
                        } else {
                            ContentUnavailableView("Files unavailable", systemImage: "folder", description: Text("Enable project file access in desktop ZedLink settings."))
                        }
                    case .changes:
                        changes
                    case .terminal:
                        NativeTerminalScreen(embedded: true)
                    case .debug:
                        debugger
                    case .activity:
                        ScrollView {
                            if let snapshot = session.snapshot {
                                ActivityPanel(snapshot: snapshot, expanded: $activityExpanded).padding(12)
                            } else {
                                ContentUnavailableView("No activity", systemImage: "clock")
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ZLTheme.background)
            .navigationTitle("Workspace").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismissZedLinkKeyboard(); dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close workspace").accessibilityIdentifier("close-workspace")
                }
            }
            .task(id: tab) { await session.loadProjectContext(page: WorkspacePage(rawValue: tab.rawValue.lowercased())) }
            .onChange(of: session.changesRevision) { _, _ in selectedDiffLine = nil }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var changes: some View {
        let diffIndex = ReviewIndex(session.diffContent)
        return VStack(spacing: 0) {
            HStack {
                Button("Refresh diff") { Task { await session.loadDiff() } }
                    .disabled(session.state != .live || !session.capabilities.contains("changes.diff") || session.changesRevision == nil || session.diffLoading)
                Spacer()
                Text("\(session.changes.count) files").font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
            }.padding(12)
            if !session.changes.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.changes) { change in
                            let section = diffIndex.sections.first { $0.title == change.id }
                            let nextStart = section.flatMap { match in diffIndex.sections.first { $0.id > match.id }?.id } ?? (diffIndex.lines.count + 1)
                            let loadedLines = section.map { match in diffIndex.lines.filter { $0.id >= match.id && $0.id < nextStart } } ?? []
                            let added = loadedLines.filter { $0.kind == .added }.count
                            let removed = loadedLines.filter { $0.kind == .removed }.count
                            HStack(spacing: 8) {
                                Button {
                                    selectedDiffLine = section?.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(change.id).font(.footnote.monospaced()).lineLimit(2)
                                        Text("\(change.status) · \(change.staging)" + (section == nil ? "" : " · +\(added) −\(removed) in loaded diff"))
                                            .font(.caption).foregroundStyle(ZLTheme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).disabled(section == nil)
                                Button(change.staging == "staged" ? "Unstage" : "Stage") { Task { await session.mutateChange(change) } }
                                    .font(.caption).disabled(session.state != .live || !session.capabilities.contains(change.staging == "staged" ? "changes.unstage" : "changes.stage"))
                            }.padding(.horizontal, 12).frame(minHeight: 52)
                            Hairline()
                        }
                    }
                }.frame(maxHeight: 188)
            }
            if session.diffLoading { ProgressView("Loading diff…").frame(maxHeight: .infinity) }
            else if !session.capabilities.contains("changes.snapshot") {
                ContentUnavailableView("Changes unavailable", systemImage: "lock")
            } else if session.changes.isEmpty {
                ContentUnavailableView("No working tree changes", systemImage: "checkmark.circle")
            } else if session.diffContent.isEmpty {
                ContentUnavailableView("Review changes", systemImage: "doc.text", description: Text("Choose Refresh diff to load the current native revision."))
            } else {
                CodeReviewView(content: session.diffContent, title: "Changes", diff: true, truncated: session.diffTruncated, initialLine: selectedDiffLine)
                    .id(selectedDiffLine)
            }
        }
    }

    private var debugger: some View {
        List {
                Section("Debugger") {
                    if !session.capabilities.contains("debugger.catalog") {
                        Text("Enable Start Configured Debuggers in desktop ZedLink settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if session.debuggerCatalog.isEmpty {
                        Text("No configured Zed debuggers are available for this project.").foregroundStyle(.secondary)
                    }
                    ForEach(session.debuggerCatalog) { scenario in
                        Button {
                            Task { await session.launchDebugger(scenario) }
                        } label: {
                            HStack { Text(scenario.label); Spacer(); Text(scenario.adapter.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        .disabled(session.state != .live || !session.capabilities.contains("debugger.launch"))
                    }
                    if !session.capabilities.contains("debugger.snapshot") {
                        Text("Enable View Debugger Sessions in desktop ZedLink settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if session.debuggerSessions.isEmpty {
                        Text("No debugger session is running in this Zed project.").foregroundStyle(.secondary)
                    }
                    ForEach(session.debuggerSessions) { debugger in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(debugger.label)
                                    Text(debugger.adapter).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !debugger.terminated {
                                    Menu("Session") {
                                        if debugger.canRestart {
                                            Button("Restart") { Task { await session.controlDebugger(debugger, action: "restart") } }
                                        }
                                        Button("Stop", role: .destructive) { Task { await session.controlDebugger(debugger, action: "stop") } }
                                    }.disabled(session.state != .live || !session.capabilities.contains("debugger.control"))
                                }
                            }
                            ForEach(debugger.threads) { thread in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(thread.name)
                                        Text(thread.status.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Menu("Controls") {
                                        if thread.status == "running" {
                                            Button("Pause") { Task { await session.controlDebugger(debugger, action: "pause", thread: thread) } }
                                        } else if thread.status == "stopped" {
                                            Button("Continue") { Task { await session.controlDebugger(debugger, action: "continue", thread: thread) } }
                                            Button("Step over") { Task { await session.controlDebugger(debugger, action: "step_over", thread: thread) } }
                                            Button("Step into") { Task { await session.controlDebugger(debugger, action: "step_in", thread: thread) } }
                                            Button("Step out") { Task { await session.controlDebugger(debugger, action: "step_out", thread: thread) } }
                                            if debugger.canStepBack {
                                                Button("Step back") { Task { await session.controlDebugger(debugger, action: "step_back", thread: thread) } }
                                            }
                                        }
                                    }.disabled(session.state != .live || !session.capabilities.contains("debugger.control"))
                                }
                            }
                        }
                    }
                }
        }.scrollContentBackground(.hidden)
            .refreshable { await session.loadProjectContext(page: .debug) }
    }
}

private struct ActivityPanel: View {
    @EnvironmentObject private var session: SessionManager
    let snapshot: ThreadSnapshot
    @Binding var expanded: Bool

    private var items: [NativeEntryPresentation] {
        snapshot.activityEntries.enumerated().map { NativeEntryPresentation($0.element, index: $0.offset) }
    }
    private var reasoning: [String] { items.flatMap(\.reasoning) }
    private var tools: [NativeEntryPresentation] { items.filter { $0.kind == .tool } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: snapshot.isBusy ? "waveform" : "clock.arrow.circlepath")
                        .foregroundStyle(snapshot.isBusy ? ZLTheme.focus : ZLTheme.muted)
                    Text(snapshot.isBusy ? session.liveActivity.displayText : "Recent activity").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(snapshot.isBusy ? "LIVE" : "DONE").font(.caption2.monospaced())
                        .foregroundStyle(snapshot.isBusy ? ZLTheme.focus : ZLTheme.muted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .padding(11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    if reasoning.isEmpty && tools.isEmpty {
                        Text("Waiting for reasoning or tool activity shared by native Zed…")
                            .font(.footnote).foregroundStyle(ZLTheme.muted)
                    }
                    ForEach(Array(reasoning.enumerated()), id: \.offset) { _, value in
                        VStack(alignment: .leading, spacing: 5) {
                            SectionLabel("Reasoning shared by Zed")
                            NativeMarkdownView(markdown: value)
                        }
                    }
                    ForEach(tools) { tool in
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                            Text(tool.toolName ?? "Zed tool").lineLimit(1)
                            Spacer()
                            Text(tool.toolStatus ?? "Updated").font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                        }
                        .font(.footnote)
                    }
                    if snapshot.activityTruncated {
                        Text("Earlier activity is omitted from this live window.")
                            .font(.caption).foregroundStyle(ZLTheme.muted)
                    }
                }
                .padding(12)
            }
        }
        .background(ZLTheme.surface)
        .overlay(Rectangle().stroke(ZLTheme.line, lineWidth: 1))
        .accessibilityIdentifier("live-activity")
    }
}

/// Compare raw entries before parsing Markdown, so unchanged transcript rows stay idle while streaming.
struct NativeEntryView: View, Equatable {
    let markdown: String
    let index: Int
    let thinkingLive: Bool

    static func == (left: Self, right: Self) -> Bool {
        left.index == right.index && left.thinkingLive == right.thinkingLive && left.markdown == right.markdown
    }

    var body: some View {
        NativeMessageView(message: NativeEntryPresentation(markdown, index: index), thinkingLive: thinkingLive)
    }
}

struct NativeMessageView: View, Equatable {
    let message: NativeEntryPresentation
    let thinkingLive: Bool

    static func == (left: Self, right: Self) -> Bool {
        left.message == right.message && left.thinkingLive == right.thinkingLive
    }

    private var selectableText: String {
        ([message.body] + message.reasoning).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var copyMessageButton: some View {
        Button { UIPasteboard.general.string = selectableText } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption).foregroundStyle(ZLTheme.muted)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy entire message")
        .accessibilityIdentifier("copy-message-\(message.id)")
    }

    var body: some View { content }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 42)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 4) {
                        SectionLabel(message.label)
                        Spacer(minLength: 0)
                        if !selectableText.isEmpty { copyMessageButton }
                    }
                    NativeMarkdownView(markdown: message.body)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(ZLTheme.raised)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        case .tool:
            ToolMessageView(message: message, copyText: selectableText).padding(.horizontal, 14).padding(.vertical, 10)
        default:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    SectionLabel(message.label)
                    Spacer(minLength: 0)
                    if !selectableText.isEmpty { copyMessageButton }
                }
                ForEach(Array(message.reasoning.enumerated()), id: \.offset) { _, thought in
                    ThinkingDisclosure(thought: thought, live: thinkingLive)
                }
                if !message.body.isEmpty { NativeMarkdownView(markdown: message.body) }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ThinkingDisclosure: View {
    let thought: String
    let live: Bool
    @State private var expanded: Bool

    init(thought: String, live: Bool) {
        self.thought = thought
        self.live = live
        _expanded = State(initialValue: live)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            NativeMarkdownView(markdown: thought).padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                if live {
                    ProgressView().controlSize(.mini).tint(ZLTheme.focus)
                }
                Text(live ? "Thinking" : "Thinking · complete")
            }
        }
        .font(.footnote)
        .tint(ZLTheme.muted)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(ZLTheme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(ZLTheme.line).frame(width: 2) }
        .onChange(of: live) { _, active in if active { expanded = true } }
    }
}

private struct ToolMessageView: View {
    let message: NativeEntryPresentation
    let copyText: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "terminal").foregroundStyle(ZLTheme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.toolName ?? "Zed tool").font(.subheadline.weight(.medium)).lineLimit(2)
                            Text(message.toolStatus ?? "Native tool activity")
                                .font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel(expanded ? "Hide tool details" : "Show tool details")
                if !copyText.isEmpty {
                    Button { UIPasteboard.general.string = copyText } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption).foregroundStyle(ZLTheme.muted)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy entire message")
                    .accessibilityIdentifier("copy-message-\(message.id)")
                }
            }
            if expanded { Hairline(); NativeMarkdownView(markdown: message.body) }
        }
        .padding(12).background(ZLTheme.surface)
        .overlay(Rectangle().stroke(ZLTheme.line, lineWidth: 1))
    }
}

struct NativeApprovalView: View {
    @EnvironmentObject private var session: SessionManager
    let approval: NativeApproval
    @State private var expanded = false
    @State private var showingOtherChoices = false

    private var oneTimeChoices: [NativeApprovalDecision] {
        guard approval.authorizationKind == "permission_grant" else { return [] }
        return approval.decisions.filter { $0.optionKind == "allow_once" || $0.optionKind == "reject_once" }
    }

    private var otherChoices: [NativeApprovalDecision] {
        approval.decisions.filter { !oneTimeChoices.contains($0) }
    }

    private var scopes: [String] {
        var seen = Set<String>()
        return otherChoices.compactMap { choice in
            guard choice.action != nil, seen.insert(choice.label).inserted else { return nil }
            return choice.label
        }
    }

    private var otherChoiceTitle: String {
        otherChoices.allSatisfy { $0.optionKind.hasSuffix("always") } ? "Remember a choice…" : "More choices…"
    }

    private func unavailable(_ choice: NativeApprovalDecision) -> Bool {
        session.state != .live || session.resolvingApprovals.contains(approval.id) ||
        !session.capabilities.contains("approval.respond") ||
        (approval.detailsTruncated && (!choice.isRejecting || approval.authorizationKind == "action_choice"))
    }

    private func decisionButton(_ choice: NativeApprovalDecision, title: String, primary: Bool = false) -> some View {
        Button {
            dismissZedLinkKeyboard()
            Task { await session.respond(to: approval, with: choice) }
        } label: {
            HStack(spacing: 7) {
                if approval.authorizationKind == "permission_grant" {
                    Image(systemName: choice.isRejecting ? "xmark" : "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primary ? ZLTheme.background : ZLTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .background(primary ? ZLTheme.ink : ZLTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? ZLTheme.ink : ZLTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable(choice))
        .accessibilityLabel(approval.authorizationKind == "permission_grant" && choice.optionKind == "allow_once" ? "Allow once" : approval.authorizationKind == "permission_grant" && choice.optionKind == "reject_once" ? "Deny once" : choice.displayLabel)
        .accessibilityHint(choice.optionKind.hasSuffix("always") ? "Saves this permission choice in desktop Zed" : choice.optionKind.hasSuffix("once") ? "Applies to this request only" : "Choose this native Zed action")
        .accessibilityIdentifier("approval-choice-" + choice.id)
    }

    private var remainingChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(scopes, id: \.self) { scope in
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope).font(.footnote).foregroundStyle(ZLTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        ForEach(otherChoices.filter { $0.label == scope && $0.action != nil }) { choice in
                            decisionButton(choice, title: choice.action == "allow" ? "Allow" : choice.action == "deny" ? "Deny" : choice.displayLabel)
                        }
                    }
                }
            }
            ForEach(otherChoices.filter { $0.action == nil }) { choice in
                decisionButton(choice, title: choice.displayLabel)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.authorizationKind == "action_choice" ? "Action needed" : "Permission needed", systemImage: "hand.raised")
                .font(.footnote.weight(.semibold)).foregroundStyle(ZLTheme.warning)
            Text(approval.display)
                .font(.subheadline.weight(.medium))
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(approval.toolName).font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(expanded ? "Hide details" : "Review details", systemImage: expanded ? "chevron.up" : "chevron.down") {
                    expanded.toggle()
                }.font(.caption).frame(minHeight: 44)
            }
            if let input = approval.rawInput, expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(input).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8).background(ZLTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if approval.detailsTruncated {
                Label(approval.authorizationKind == "action_choice"
                      ? "Details are incomplete. Resolve this request in desktop Zed."
                      : "Details are incomplete. Allow is unavailable until the full request can be reviewed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(ZLTheme.warning)
            }
            if session.resolvingApprovals.contains(approval.id) { ProgressView("Sending decision…") }
            if approval.decisions.isEmpty {
                Text("Update patched Zed to resolve this request remotely.")
                    .font(.caption2).foregroundStyle(ZLTheme.muted)
            } else {
                if !oneTimeChoices.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(oneTimeChoices) { choice in
                                decisionButton(choice,
                                               title: choice.isRejecting ? "Deny once" : "Allow once",
                                               primary: !choice.isRejecting)
                                    .frame(minWidth: 140)
                            }
                        }
                        VStack(spacing: 8) {
                            ForEach(oneTimeChoices) { choice in
                                decisionButton(choice,
                                               title: choice.isRejecting ? "Deny once" : "Allow once",
                                               primary: !choice.isRejecting)
                            }
                        }
                    }
                }
                if !otherChoices.isEmpty {
                    if oneTimeChoices.isEmpty {
                        remainingChoices
                    } else {
                        DisclosureGroup(isExpanded: $showingOtherChoices) {
                            remainingChoices.padding(.top, 7)
                        } label: {
                            Text(otherChoiceTitle)
                                .font(.footnote.weight(.medium))
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .tint(ZLTheme.ink)
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ZLTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZLTheme.line, lineWidth: 1))
        .accessibilityIdentifier("native-approval")
    }
}

private struct NativeElicitationView: View {
    @EnvironmentObject private var session: SessionManager
    let elicitation: NativeElicitation
    @State private var values: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var validation = ""
    private var submitting: Bool { session.isRespondingToElicitation(elicitation.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INPUT REQUESTED").font(.caption2.monospaced().weight(.semibold)).foregroundStyle(ZLTheme.warning)
            Text(elicitation.message).font(.subheadline.weight(.semibold))
            if let url = elicitation.url, let destination = URL(string: url) { Link("Open secure input page", destination: destination) }
            ForEach(elicitation.fields) { field in
                let title = field.title + (field.required ? " *" : "")
                if field.type == "boolean" {
                    Toggle(title, isOn: Binding(get: { ElicitationForm.value(field, values: values) == "true" }, set: { values[field.id] = $0 ? "true" : "false" }))
                } else if field.type == "array", !field.choices.isEmpty {
                    Text(title).font(.caption)
                    ForEach(field.choices, id: \.self) { choice in
                        Toggle(choice, isOn: Binding(get: { (selections[field.id] ?? ElicitationForm.arrayDefault(field)).contains(choice) }, set: { enabled in
                            var selected = selections[field.id] ?? ElicitationForm.arrayDefault(field)
                            if enabled { selected.insert(choice) } else { selected.remove(choice) }; selections[field.id] = selected
                        }))
                    }
                } else if !field.choices.isEmpty {
                    Picker(title, selection: Binding(get: { ElicitationForm.value(field, values: values) }, set: { values[field.id] = $0 })) {
                        if !field.required { Text("No value").tag("") }
                        ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField(title, text: Binding(get: { ElicitationForm.value(field, values: values) }, set: { values[field.id] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(8).overlay(Rectangle().stroke(ZLTheme.line))
                    if field.type == "array" { Text("Separate values with commas.").font(.caption) }
                }
            }.disabled(submitting)
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(ZLTheme.danger) }
            if submitting { ProgressView("Submitting response…") }
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    dismissZedLinkKeyboard()
                    Task { await session.respondToElicitation(elicitation, action: "decline") }
                } label: { Text("Decline").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered)
                Button {
                    do {
                        let content = try ElicitationForm.content(elicitation.fields, values: values, selections: selections)
                        validation = ""; dismissZedLinkKeyboard()
                        Task { await session.respondToElicitation(elicitation, action: "accept", content: content) }
                    } catch { validation = error.localizedDescription }
                } label: { Text("Submit").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(ZLPrimaryButtonStyle())
            }.disabled(session.state != .live || submitting || !session.capabilities.contains("elicitation.respond"))
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(ZLTheme.surface).overlay(Rectangle().stroke(ZLTheme.warning.opacity(0.5)))
    }
}

@MainActor private struct SlashCommandPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @ObservedObject var library: ComposerLibrary
    let scope: ComposerScope?
    let choose: (NativeCommand) -> Void
    @State private var search = ""
    @State private var category = "All"

    private var categories: [String] {
        ["All"] + Array(Set(session.commands.map(\.category))).sorted()
    }

    private var commands: [NativeCommand] {
        session.commands.filter { command in
            (category == "All" || command.category == category) &&
                (search.isEmpty || command.name.localizedCaseInsensitiveContains(search) ||
                 command.description.localizedCaseInsensitiveContains(search) ||
                 command.inputHint?.localizedCaseInsensitiveContains(search) == true)
        }
    }

    private var pinnedCommands: [NativeCommand] {
        guard let scope else { return [] }
        return library.pinned(in: scope).compactMap { name in commands.first(where: { $0.name == name }) }
    }

    private var recentCommands: [NativeCommand] {
        guard let scope else { return [] }
        let pinned = Set(pinnedCommands.map(\.name))
        return library.recent(in: scope).compactMap { name in
            pinned.contains(name) ? nil : commands.first(where: { $0.name == name })
        }
    }

    private var otherCommands: [NativeCommand] {
        let highlighted = Set((pinnedCommands + recentCommands).map(\.name))
        return commands.filter { !highlighted.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These commands come from the selected Zed Agent thread. Choose one for your draft, or pin it for quick access in +.")
                        .font(.footnote).foregroundStyle(ZLTheme.muted)
                    if categories.count > 2 {
                        Picker("Category", selection: $category) {
                            ForEach(categories, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if commands.isEmpty {
                    Section("Slash commands") {
                        Text(session.commands.isEmpty
                             ? "No slash commands are advertised by this thread. Reconnect or refresh to check again."
                             : "No commands match this search or category.")
                            .foregroundStyle(ZLTheme.muted)
                    }
                }
                if !pinnedCommands.isEmpty {
                    Section("Pinned") {
                        ForEach(pinnedCommands) { command in commandRow(command) }
                    }
                }
                if !recentCommands.isEmpty {
                    Section("Recently chosen") {
                        ForEach(recentCommands) { command in commandRow(command) }
                    }
                }
                if !otherCommands.isEmpty {
                    Section("All commands") {
                        ForEach(otherCommands) { command in commandRow(command) }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(ZLTheme.background)
            .searchable(text: $search, prompt: "Search slash commands")
            .task { await session.refreshCommands() }
            .navigationTitle("Slash commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await session.refreshCommands() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh slash commands")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commandRow(_ command: NativeCommand) -> some View {
        HStack(spacing: 8) {
            Button {
                choose(command)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("/\(command.name)").font(.body.monospaced().weight(.semibold))
                        Spacer()
                        Text(command.category.uppercased()).font(.caption2.monospaced())
                            .foregroundStyle(ZLTheme.muted)
                    }
                    Text(command.description).font(.footnote).foregroundStyle(.secondary)
                    if let hint = command.inputHint {
                        Text(hint).font(.caption.monospaced()).foregroundStyle(ZLTheme.muted)
                    }
                    if let warning = command.warning {
                        Text(warning).font(.caption).foregroundStyle(ZLTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("slash-command-\(command.name)")
            if let scope {
                let isPinned = library.pinned(in: scope).contains(command.name)
                Button { library.togglePin(command.name, in: scope) } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPinned ? "Unpin /\(command.name)" : "Pin /\(command.name)")
                .accessibilityIdentifier("slash-pin-\(command.name)")
            }
        }
    }
}

private struct NativeTerminalScreen: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionManager
    @State private var input = ""
    @State private var sending = false
    @State private var followOutput = true
    @AppStorage("zedlink.terminalWrap") private var wrapOutput = true
    @State private var showingClipboard = false
    @FocusState private var keyboardFocused: Bool
    private let keys: [(String, String)] = [("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl C", "\u{03}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C")]

    private var recoveryKey: String { "zedlink.terminalDraft.\(session.profile?.id.uuidString ?? "").\(session.targetID ?? "").\(session.instanceID ?? "").\(session.epoch ?? "").\(session.terminalSnapshot?.terminal.id ?? "")" }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }.presentationDetents([.large])
    }

    private var content: some View {
            VStack(spacing: 0) {
                if !embedded { SessionIssueBanner() }
                HStack {
                    Menu {
                        ForEach(Array(session.terminals.enumerated()), id: \.element.id) { index, terminal in
                            Button {
                                keyboardFocused = false
                                Task { await session.loadTerminal(terminal) }
                            } label: {
                                Label("\(index + 1). \(terminal.title)", systemImage: session.terminalSnapshot?.terminal.id == terminal.id ? "checkmark" : "terminal")
                            }
                        }
                    } label: { Text(session.terminalSnapshot?.terminal.title ?? "Choose terminal").lineLimit(1) }.disabled(sending || session.creatingTerminal)
                    Button {
                        keyboardFocused = false
                        Task { await session.createTerminal() }
                    } label: {
                        if session.creatingTerminal { ProgressView() }
                        else { Image(systemName: "plus").frame(width: 44, height: 44) }
                    }.accessibilityLabel("New terminal")
                        .disabled(session.creatingTerminal || session.state != .live || !session.capabilities.contains("terminal.create"))
                    Menu {
                        Toggle("Wrap output", isOn: $wrapOutput)
                        if session.capabilities.contains("task.catalog") {
                            Menu("Run configured task") {
                                ForEach(session.configuredTasks) { task in
                                    Button(task.label) { Task { await session.runConfiguredTask(task) } }
                                        .disabled(!session.capabilities.contains("task.run"))
                                }
                            }
                        }
                        Button("Remote clipboard") { showingClipboard = true }
                        Button("Recover session") { Task { await session.refresh(); await session.loadProjectContext(page: .terminal) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    Spacer()
                    Text(session.capabilities.contains("terminal.input") ? "Interactive" : "Read only").font(.caption)
                    if !followOutput { Button("Latest") { followOutput = true }.font(.caption) }
                    if session.terminalSnapshot?.terminal.taskState == "running" && session.capabilities.contains("task.stop") {
                        Button("Stop", role: .destructive) { Task { await session.stopTerminalTask() } }.font(.caption)
                    }
                }.padding(10)
                GeometryReader { geometry in
                ScrollViewReader { reader in
                ScrollView(wrapOutput ? .vertical : [.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                    if session.terminalSnapshot == nil {
                        ContentUnavailableView {
                            Label("No terminal selected", systemImage: "terminal")
                        } description: {
                            Text(session.capabilities.contains("terminal.create") ? "Start a terminal in this Zed workspace." : "Open one in desktop Zed. Remote creation requires an updated bridge and terminal viewing/input permissions.")
                        } actions: {
                            if session.capabilities.contains("terminal.create") {
                                Button(session.creatingTerminal ? "Starting terminal…" : "New terminal") { Task { await session.createTerminal() } }
                                    .disabled(session.creatingTerminal || session.state != .live)
                            }
                        }
                    }
                    terminalText(session.terminalSnapshot)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: !wrapOutput, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
                    Color.clear.frame(height: 1).id("terminal-bottom")
                    }
                }.background(Color.black).foregroundStyle(Color.white)
                    .simultaneousGesture(DragGesture().onChanged { _ in followOutput = false })
                .onChange(of: session.terminalSnapshot?.content) { _, _ in if followOutput { reader.scrollTo("terminal-bottom", anchor: .bottom) } }
                .onChange(of: followOutput) { _, follow in if follow { reader.scrollTo("terminal-bottom", anchor: .bottom) } }
                }
                .task(id: "\(session.terminalSnapshot?.terminal.id ?? ""):\(Int(geometry.size.width)):\(Int(geometry.size.height))") {
                    let columns = min(max(Int((geometry.size.width - 20) / 7.3), 24), 120)
                    let rows = min(max(Int((geometry.size.height - 20) / 16), 8), 80)
                    await session.resizeTerminal(columns: columns, rows: rows)
                }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
                if session.capabilities.contains("terminal.input") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(keys, id: \.0) { key in
                                Button(key.0) {
                                    let pending = input; sending = true
                                    Task {
                                        defer { sending = false }
                                        if !pending.isEmpty {
                                            guard await session.sendTerminalInput(pending, appendReturn: false) else { return }
                                            if input == pending { input = "" }
                                        }
                                        await session.sendTerminalInput(key.1, appendReturn: false)
                                    }
                                }.font(.system(size: 13, design: .monospaced)).frame(minWidth: 44, minHeight: 44)
                                    .background(ZLTheme.surface).disabled(sending || session.state != .live || session.terminalSnapshot == nil)
                            }
                        }.padding(6)
                    }
                    HStack {
                        Text("›").foregroundStyle(ZLTheme.healthy)
                        TextField("Command or reply", text: $input).focused($keyboardFocused)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                            .submitLabel(.send).onSubmit { send() }
                        VoiceDraftButton(text: $input, scope: recoveryKey)
                        Button { send() } label: { Image(systemName: "return") }.frame(width: 44, height: 44).disabled(sending || session.state != .live || session.terminalSnapshot == nil)
                    }.padding(.horizontal, 10)
                } else { Text("Enable Send Terminal Input in desktop ZedLink settings.").font(.caption).padding(10) }
            }
            .task(id: recoveryKey) { input = UserDefaults.standard.string(forKey: recoveryKey) ?? "" }
            .onChange(of: input) { _, value in if session.terminalSnapshot != nil { UserDefaults.standard.set(value, forKey: recoveryKey) } }
            .sheet(isPresented: $showingClipboard) { RemoteClipboardView { input = $0 } }
            .navigationTitle(embedded ? "Workspace" : "Terminal").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { keyboardFocused = false; dismiss() } }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide keyboard") { keyboardFocused = false } }
            }
            .task {
                await session.loadProjectContext(page: .terminal)
                if session.terminalSnapshot == nil, let terminal = session.terminals.first {
                    await session.loadTerminal(terminal)
                }
                while !Task.isCancelled {
                    if let terminal = session.terminalSnapshot?.terminal { await session.loadTerminal(terminal, refresh: true) }
                    do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
                }
            }
    }

    private func send() {
        guard !sending, session.state == .live, session.terminalSnapshot != nil else { return }
        let value = input; sending = true
        Task {
            defer { sending = false }
            if await session.sendTerminalInput(value.isEmpty ? "\r" : value + "\n", appendReturn: false) { if input == value { input = "" } }
        }
    }
}


private let terminalFontRegistered: Bool = {
    guard let url = Bundle.main.url(forResource: "terminal-icons", withExtension: "ttf") else { return false }
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}()

private func terminalColor(_ hex: String) -> Color? {
    guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}

private func terminalText(_ snapshot: NativeTerminalSnapshot?) -> Text {
    guard let snapshot else { return Text("") }
    var text = AttributedString()
    let runs = snapshot.styledRuns.isEmpty ? [NativeTerminalRun(text: snapshot.content, foreground: "", background: "", bold: false, italic: false, underline: false, dim: false)] : snapshot.styledRuns
    for run in runs {
        var segments: [(String, Bool)] = []
        for character in run.text {
            let scalar = character.unicodeScalars.first?.value ?? 0
            let icon = (0xe5fa...0xe6b7).contains(scalar) || (0xe700...0xe8ef).contains(scalar) || (0xf000...0xf2e0).contains(scalar) || (0xf400...0xf533).contains(scalar) || (0xf0001...0xf1af0).contains(scalar)
            if segments.last?.1 == icon {
                segments[segments.count - 1].0.append(character)
            } else { segments.append((String(character), icon)) }
        }
        for (segment, icon) in segments {
            var part = AttributedString(segment)
            var font = icon && terminalFontRegistered ? Font.custom("SymbolsNFM", size: 12) : Font.system(size: 12, design: .monospaced)
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            part.font = font
            if let color = terminalColor(run.foreground) { part.foregroundColor = run.dim ? color.opacity(0.7) : color }
            if let color = terminalColor(run.background) { part.backgroundColor = color }
            if run.underline { part.underlineStyle = Text.LineStyle(pattern: .solid) }
            text += part
        }
    }
    return Text(text)
}
