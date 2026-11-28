import SwiftUI

/// One usage bar of a subscription window (`limits.list`).
struct LimitBar: View {
    let window: LimitWindow
    var height: CGFloat = 6

    private var tint: Color {
        if window.status == "rejected" || window.usedPercent >= 95 { return ZLTheme.danger }
        if window.status == "allowed_warning" || window.usedPercent >= 80 { return ZLTheme.warning }
        return ZLTheme.healthy
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ZLTheme.line)
                Capsule().fill(tint)
                    .frame(width: max(window.usedPercent > 0 ? height : 0, geometry.size.width * window.fraction))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The card at the top of Summary: one line per agent with a bar for each window.
struct LimitsCard: View {
    let limits: [GatewayLimits]

    private var showsConnection: Bool { limits.filter { !$0.agents.isEmpty }.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Лимиты", systemImage: "gauge")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ZLTheme.ink)
            ForEach(limits) { gateway in
                ForEach(gateway.agents) { agent in
                    agentLine(agent, connection: showsConnection ? gateway.connectionName : nil)
                }
            }
        }
        .padding(12)
        .background(ZLTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary-limits-card")
    }

    private func agentLine(_ agent: AgentLimits, connection: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(connection.map { "\(agent.label) · \($0)" } ?? agent.label)
                    .font(.caption.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let tightest = agent.tightest {
                    Text(summary(tightest)).font(.caption2.monospacedDigit()).foregroundStyle(ZLTheme.muted).lineLimit(1)
                }
            }
            if agent.windows.isEmpty {
                Text("Нет данных").font(.caption2).foregroundStyle(ZLTheme.muted)
            } else {
                HStack(spacing: 6) {
                    ForEach(agent.windows) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            LimitBar(window: window)
                            Text(window.label).font(.caption2).foregroundStyle(ZLTheme.muted).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ window: LimitWindow) -> String {
        var parts: [String] = [ExtrasFormat.percent(window.usedPercent)]
        if let resetsAt = window.resetsAt, !window.reset { parts.append(ExtrasFormat.reset(resetsAt)) }
        return parts.joined(separator: " · ")
    }
}

/// Every window of every agent, with when it was observed and where the value came from.
struct LimitsView: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        List {
            if extras.limits.allSatisfy({ $0.agents.isEmpty }) {
                Text(extras.limitsRefreshing ? "Загружаю лимиты…" : "Данных о лимитах пока нет. Claude сообщает их во время хода агента, Codex — в своём журнале сессий.")
                    .font(.subheadline).foregroundStyle(ZLTheme.muted)
            }
            ForEach(extras.limitsIssues.keys.sorted(), id: \.self) { name in
                Label("\(name): \(extras.limitsIssues[name] ?? "") · показаны последние данные", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(ZLTheme.warning)
            }
            ForEach(extras.limits) { gateway in
                ForEach(gateway.agents) { agent in
                    Section {
                        ForEach(agent.windows) { window in windowRow(window) }
                        if agent.windows.isEmpty {
                            Text("Окна лимитов не сообщались.").font(.footnote).foregroundStyle(ZLTheme.muted)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let observedAt = agent.observedAt {
                                Text("Замер: \(ExtrasFormat.time(observedAt)) (\(observedAt.formatted(.relative(presentation: .named))))")
                            } else {
                                Text("Время замера неизвестно")
                            }
                            Text("Источник: \(agent.sourceLabel)")
                        }
                        .font(.caption).foregroundStyle(ZLTheme.muted)
                    } header: {
                        SectionLabel(extras.limits.count > 1 ? "\(agent.label) · \(gateway.connectionName)" : agent.label)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(ZLTheme.background)
        .navigationTitle("Лимиты").navigationBarTitleDisplayMode(.inline)
        .refreshable { await extras.refreshLimits(profiles: profiles.profiles, preferring: session.profile) }
        .task { await extras.refreshLimits(profiles: profiles.profiles, preferring: session.profile) }
    }

    private func windowRow(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.subheadline.weight(.medium))
                Spacer()
                Text(ExtrasFormat.percent(window.usedPercent)).font(.subheadline.monospacedDigit())
            }
            LimitBar(window: window, height: 8)
            HStack(spacing: 6) {
                if window.reset {
                    Text("окно сброшено, ждём новый замер")
                } else if let resetsAt = window.resetsAt {
                    Text(ExtrasFormat.reset(resetsAt))
                }
                if let status = window.statusLabel { Text("· " + status) }
            }
            .font(.caption).foregroundStyle(ZLTheme.muted)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
