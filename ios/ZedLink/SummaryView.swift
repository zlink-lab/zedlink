import SwiftUI

/// "Сводка": recent threads across every saved connection, host and workspace, newest first.
/// Rows are kept on the phone, so the tab still reads when a gateway is offline.
struct SummaryView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var summary: SummaryStore
    @Binding var selectedTab: Int
    @State private var search = ""
    @State private var historyLimit = 40
    @State private var opening: String?

    private let recentWindow: TimeInterval = 3 * 24 * 60 * 60

    private var matching: [SummaryEntry] {
        summary.entries.filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }

    private var recent: [SummaryEntry] {
        let now = Date()
        return matching.filter { now.timeIntervalSince($0.updatedAt) <= recentWindow }
    }

    private var history: [SummaryEntry] {
        let now = Date()
        return matching.filter { now.timeIntervalSince($0.updatedAt) > recentWindow }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                recentSection
                historySection
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(ZLTheme.background)
            .searchable(text: $search, prompt: "Search all connections")
            .navigationTitle("Сводка").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await summary.refresh(profiles: profiles.profiles) } } label: {
                        if summary.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(summary.refreshing || profiles.profiles.isEmpty)
                    .accessibilityLabel("Refresh summary")
                }
            }
            .refreshable { await summary.refresh(profiles: profiles.profiles) }
            .task {
                while !Task.isCancelled {
                    await summary.refresh(profiles: profiles.profiles)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onChange(of: search) { _, _ in historyLimit = 40 }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if profiles.profiles.isEmpty {
            Text("Pair a gateway in Settings › Connections to see its threads here.")
                .font(.subheadline).foregroundStyle(ZLTheme.muted)
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
        Button { open(entry) } label: { SummaryRow(entry: entry, opening: opening == entry.id) }
            .buttonStyle(.plain)
            .disabled(opening != nil)
            .listRowBackground(ZLTheme.background)
            .accessibilityIdentifier("summary-thread-" + entry.threadID)
    }

    private func open(_ entry: SummaryEntry) {
        opening = entry.id
        Task {
            defer { opening = nil }
            selectedTab = 0
            let opened: Bool = await session.openThread(gatewayID: entry.gatewayID, targetID: entry.targetID,
                                                        threadID: entry.threadID, hostID: entry.hostID,
                                                        projectID: entry.projectID, profiles: profiles.profiles)
            if opened, let profile = session.profile { profiles.markUsed(profile) }
        }
    }
}

private struct SummaryRow: View {
    let entry: SummaryEntry
    let opening: Bool

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
