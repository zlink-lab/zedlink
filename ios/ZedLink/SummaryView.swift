import SwiftUI

/// Screens pushed on the Summary tab's own navigation stack (§6.7): a thread opened here (or from
/// a push) pops back to Summary, not to the Sessions list.
enum SummaryRoute: Hashable {
    case thread(String)
    case limits
    case statistics
    case autopilotHistory
}

/// "Сводка": recent threads across every saved connection, host and workspace, newest first.
/// Rows are kept on the phone, so the tab still reads when a gateway is offline.
struct SummaryView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var summary: SummaryStore
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var library: SessionLibrary
    @State private var infoThread: ThreadRef?
    @Binding var path: [SummaryRoute]
    @State private var search = ""
    @State private var historyLimit = 40
    @State private var opening: String?
    /// Why the last tapped thread could not be opened (the Sessions tab shows the full issue).
    @State private var openIssue = ""

    private let recentWindow: TimeInterval = 3 * 24 * 60 * 60

    private var matching: [SummaryEntry] {
        summary.entries.filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }

    private func isPinned(_ entry: SummaryEntry) -> Bool { library.pins.contains(ThreadRef(entry: entry).pinKey) }

    private var pinned: [SummaryEntry] { matching.filter { isPinned($0) } }

    private var recent: [SummaryEntry] {
        let now = Date()
        return matching.filter { now.timeIntervalSince($0.updatedAt) <= recentWindow && !isPinned($0) }
    }

    private var history: [SummaryEntry] {
        let now = Date()
        return matching.filter { now.timeIntervalSince($0.updatedAt) > recentWindow && !isPinned($0) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                limitsSection
                statusSection
                pinnedSection
                AutopilotSummarySection()
                statisticsLink
                recentSection
                historySection
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(ZLTheme.background)
            .sheet(item: $infoThread) { ThreadInfoSheet(ref: $0) }
            .searchable(text: $search, prompt: "Search all connections")
            .navigationTitle("Сводка").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refreshAll() } } label: {
                        if summary.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(summary.refreshing || profiles.profiles.isEmpty)
                    .accessibilityLabel("Refresh summary")
                }
            }
            .refreshable { await refreshAll() }
            .task {
                while !Task.isCancelled {
                    await refreshAll()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onChange(of: search) { _, _ in historyLimit = 40 }
            .navigationDestination(for: SummaryRoute.self) { route in
                switch route {
                case .thread(let threadID): ConversationView(threadID: threadID)
                case .limits: LimitsView()
                case .statistics: StatisticsView()
                case .autopilotHistory: AutopilotHistoryView(scope: AutopilotHistoryScope())
                }
            }
        }
    }

    /// "Статистика": shown once any saved gateway reports limits or the autopilot (wave 3).
    @ViewBuilder private var statisticsLink: some View {
        if extras.allLimitAgents > 0 || !extras.autopilot.isEmpty {
            NavigationLink(value: SummaryRoute.statistics) {
                Label("Статистика токенов и лимитов", systemImage: "chart.bar.xaxis")
                    .font(.subheadline)
            }
            .listRowBackground(ZLTheme.background)
            .accessibilityIdentifier("summary-statistics")
        }
    }

    /// Threads, then unread counts, limits and the autopilot of every saved gateway.
    private func refreshAll() async {
        await summary.refresh(profiles: profiles.profiles)
        await extras.refresh(profiles: profiles.profiles, preferring: session.profile)
    }

    /// Subscription limits (`limits.list`); tap for every window. Hidden without data.
    @ViewBuilder private var limitsSection: some View {
        if extras.allLimitAgents > 0 {
            NavigationLink(value: SummaryRoute.limits) { LimitsCard(limits: extras.limits) }
                .listRowBackground(ZLTheme.background)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("summary-limits")
        }
    }

    @ViewBuilder private var statusSection: some View {
        if profiles.profiles.isEmpty {
            Text("Pair a gateway in Settings › Connections to see its threads here.")
                .font(.subheadline).foregroundStyle(ZLTheme.muted)
        }
        if !openIssue.isEmpty {
            Button { openIssue = "" } label: {
                Label(openIssue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(ZLTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Скрывает сообщение")
        }
        ForEach(summary.issues.keys.sorted(), id: \.self) { name in
            Label("\(name): \(summary.issues[name] ?? "") · showing last known", systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(ZLTheme.warning)
        }
        if summary.entries.isEmpty && !profiles.profiles.isEmpty {
            Text(summary.refreshing ? "Loading threads from your connections…" : "No threads yet.")
                .font(.subheadline).foregroundStyle(ZLTheme.muted)
        }
    }

    @ViewBuilder private var pinnedSection: some View {
        let rows: [SummaryEntry] = pinned
        if !rows.isEmpty {
            Section {
                ForEach(rows) { entry in row(entry) }
            } header: { SectionLabel("Закреплённые · \(rows.count)") }
        }
    }

    @ViewBuilder private var recentSection: some View {
        let rows: [SummaryEntry] = recent
        if !rows.isEmpty {
            Section {
                ForEach(rows) { entry in row(entry) }
            } header: { SectionLabel("Last 3 days · \(rows.count)") }
        }
    }

    @ViewBuilder private var historySection: some View {
        let rows: [SummaryEntry] = history
        if !rows.isEmpty {
            Section {
                ForEach(rows.prefix(historyLimit)) { entry in row(entry) }
                if rows.count > historyLimit {
                    Button("Show more · \(rows.count - historyLimit) remaining") { historyLimit += 40 }
                        .font(.footnote)
                        .onAppear { historyLimit += 40 }
                }
            } header: { SectionLabel("История · \(rows.count)") }
        }
    }

    private func row(_ entry: SummaryEntry) -> some View {
        Button { open(entry) } label: {
            SummaryRow(entry: entry, opening: opening == entry.id, unread: extras.unreadCount(entry.id))
        }
            .buttonStyle(.plain)
            .disabled(opening != nil)
            .listRowBackground(ZLTheme.background)
            .accessibilityIdentifier("summary-thread-" + entry.threadID)
            .threadActions(ThreadRef(entry: entry), info: $infoThread)
    }

    /// Opens the thread on this tab's stack (`summaryThreadID`), so back returns to Summary.
    private func open(_ entry: SummaryEntry) {
        opening = entry.id
        openIssue = ""
        Task {
            defer { opening = nil }
            let opened: Bool = await session.openThread(gatewayID: entry.gatewayID, targetID: entry.targetID,
                                                        threadID: entry.threadID, hostID: entry.hostID,
                                                        projectID: entry.projectID, profiles: profiles.profiles,
                                                        destination: .summary)
            if opened, let profile = session.profile { profiles.markUsed(profile) }
            else if !opened { openIssue = session.issue.isEmpty ? "Не удалось открыть тред." : session.issue }
        }
    }
}

private struct SummaryRow: View {
    let entry: SummaryEntry
    let opening: Bool
    /// Agent events since this device last read the thread (`summary.unread`); 0 hides it.
    var unread: Int = 0

    private var tint: Color {
        switch entry.status {
        case .running: ZLTheme.focus
        case .waiting: ZLTheme.warning
        case .done: ZLTheme.healthy
        case .error: ZLTheme.danger
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if opening { ProgressView().controlSize(.small) }
                else { Image(systemName: entry.status.symbol).foregroundStyle(tint) }
            }.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                PlaceBadge(host: entry.hostLabel, workspace: entry.workspaceLabel)
                Text(entry.title).font(.body.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(meta).font(.caption).foregroundStyle(ZLTheme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if unread > 0 {
                Text(unread > 99 ? "99+" : String(unread))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ZLTheme.background)
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(ZLTheme.focus, in: Capsule())
                    .accessibilityLabel("Непрочитанных: \(unread)")
                    .accessibilityIdentifier("summary-unread-" + entry.threadID)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ZLTheme.muted)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts: [String] = [entry.status.label, entry.connectionName]
        if let agent = entry.agent, !agent.isEmpty { parts.append(agent) }
        parts.append(entry.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
