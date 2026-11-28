import Charts
import SwiftUI

/// "Статистика" (§6.6): tokens per day by agent (`stats.usage`), totals, top threads and the
/// subscription utilization over time (`stats.limits`). Opened from Summary.
struct StatisticsView: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var summary: SummaryStore
    @State private var gatewayID = ""
    @State private var days = 30
    @State private var usage: UsageStats?
    @State private var usageIssue = ""
    @State private var loadingUsage = false
    @State private var agent = ""
    @State private var hours = 72
    @State private var samples: [LimitSample] = []
    @State private var samplesIssue = ""
    @State private var loadingSamples = false

    private var gateways: [ConnectionProfile] { GatewayExtrasStore.gateways(profiles.profiles, preferring: session.profile) }
    private var profile: ConnectionProfile? {
        GatewayExtrasStore.route(gatewayID: gatewayID, in: profiles.profiles, preferring: session.profile)
    }

    /// Agents with limit data on this gateway, else the agents of the token statistics.
    private var agents: [String] {
        let known: [String] = extras.limits.first(where: { $0.id == gatewayID })?.agents.map(\.agent) ?? []
        let fromUsage: [String] = usage?.agents ?? []
        let all: [String] = known + fromUsage.filter { !known.contains($0) && $0 != "?" }
        return all.isEmpty ? ["claude", "codex"] : all
    }

    private func agentLabel(_ agent: String) -> String {
        extras.limits.first(where: { $0.id == gatewayID })?.agents.first(where: { $0.agent == agent })?.label
            ?? (agent == "claude" ? "Claude" : agent == "codex" ? "Codex" : agent)
    }

    var body: some View {
        List {
            if gateways.count > 1 {
                Section {
                    Picker("Gateway", selection: $gatewayID) {
                        ForEach(gateways) { Text($0.name).tag($0.gatewayID.lowercased()) }
                    }
                }
            }
            if gateways.isEmpty {
                Text("Сначала добавьте подключение в Settings › Connections.").foregroundStyle(ZLTheme.muted)
            } else {
                tokensSection
                totalsSection
                topThreadsSection
                limitsSection
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(ZLTheme.background)
        .navigationTitle("Статистика").navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadUsage(); await loadSamples() }
        .task {
            if gatewayID.isEmpty { gatewayID = gateways.first?.gatewayID.lowercased() ?? "" }
        }
        .task(id: "\(gatewayID)|\(days)") { await loadUsage() }
        .task(id: "\(gatewayID)|\(agent)|\(hours)") { await loadSamples() }
    }

    // MARK: Tokens per day

    @ViewBuilder private var tokensSection: some View {
        Section {
            Picker("Период", selection: $days) {
                Text("7 дней").tag(7)
                Text("30 дней").tag(30)
                Text("90 дней").tag(90)
            }
            .pickerStyle(.segmented)
            if let usage, !usage.days.isEmpty {
                Chart(usage.days) { day in
                    BarMark(x: .value("День", day.day, unit: .day),
                            y: .value("Токены", day.tokens.total))
                        .foregroundStyle(by: .value("Агент", agentLabel(day.agent)))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) { Text(TokenFormat.short(tokens)) }
                        }
                    }
                }
                .frame(height: 220)
                .accessibilityIdentifier("stats-tokens-chart")
            } else {
                statusText(loading: loadingUsage, issue: usageIssue, empty: "За этот период токены не записаны.")
            }
        } header: { Text("Токены по дням") }
    }

    @ViewBuilder private var totalsSection: some View {
        if let usage, !usage.days.isEmpty {
            Section("Итого за \(days) дн.") {
                ForEach(usage.agents, id: \.self) { agent in
                    let totals = usage.totals(agent: agent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(agentLabel(agent)).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(totals.tokens.total.formatted()).font(.subheadline.monospacedDigit())
                        }
                        Text("вход \(TokenFormat.short(totals.tokens.input)) · выход \(TokenFormat.short(totals.tokens.output)) · кэш чтение \(TokenFormat.short(totals.tokens.cacheRead)) · кэш запись \(TokenFormat.short(totals.tokens.cacheWrite)) · ходов \(totals.turns)")
                            .font(.caption).foregroundStyle(ZLTheme.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private var topThreadsSection: some View {
        if let usage, !usage.threads.isEmpty {
            Section("Самые затратные треды") {
                ForEach(usage.threads.prefix(10)) { thread in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AutopilotTitles.title(summary, gatewayID: gatewayID, targetID: thread.targetID, threadID: thread.threadID))
                                .font(.subheadline).lineLimit(2)
                            Text([thread.agent.map { agentLabel($0) }, "ходов \(thread.turns)"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(ZLTheme.muted)
                        }
                        Spacer()
                        Text(TokenFormat.short(thread.tokens.total)).font(.subheadline.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Subscription utilization

    @ViewBuilder private var limitsSection: some View {
        Section {
            Picker("Агент", selection: $agent) {
                ForEach(agents, id: \.self) { Text(agentLabel($0)).tag($0) }
            }
            Picker("Окно графика", selection: $hours) {
                Text("24 ч").tag(24)
                Text("3 дня").tag(72)
                Text("7 дней").tag(168)
            }
            .pickerStyle(.segmented)
            if !samples.isEmpty {
                Chart(samples) { sample in
                    LineMark(x: .value("Время", sample.at),
                             y: .value("Использовано", sample.usedPercent))
                        .foregroundStyle(by: .value("Окно", LimitWindow.label(kind: sample.kind)))
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0.0...100.0)
                .chartYAxis {
                    AxisMarks(values: [0.0, 25.0, 50.0, 75.0, 100.0]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percent = value.as(Double.self) { Text("\(Int(percent)) %") }
                        }
                    }
                }
                .frame(height: 200)
                .accessibilityIdentifier("stats-limits-chart")
            } else {
                statusText(loading: loadingSamples, issue: samplesIssue, empty: "Замеров лимитов за это время нет.")
            }
        } header: { Text("Использование подписки") } footer: {
            Text("Gateway записывает замеры раз в 2 минуты, когда значение меняется, и не реже раза в 10 минут.")
        }
    }

    private func statusText(loading: Bool, issue: String, empty: String) -> some View {
        Group {
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю…") }
            } else {
                Text(issue.isEmpty ? empty : issue)
            }
        }
        .font(.footnote).foregroundStyle(ZLTheme.muted)
    }

    private func describe(_ error: Error) -> String {
        GatewayFailure.isUnsupported(error) ? "Этот gateway ещё не ведёт статистику." : error.localizedDescription
    }

    private func loadUsage() async {
        guard let profile else { return }
        loadingUsage = true; usageIssue = ""
        defer { loadingUsage = false }
        do {
            usage = try await extras.usageStats(profile: profile, days: days)
        } catch {
            usage = nil
            usageIssue = describe(error)
        }
        if agent.isEmpty || !agents.contains(agent) { agent = agents.first ?? "" }
    }

    private func loadSamples() async {
        guard let profile, !agent.isEmpty else { return }
        loadingSamples = true; samplesIssue = ""
        defer { loadingSamples = false }
        do {
            samples = try await extras.limitSamples(profile: profile, agent: agent, hours: hours)
        } catch {
            samples = []
            samplesIssue = describe(error)
        }
    }
}
