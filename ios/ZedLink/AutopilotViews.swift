import SwiftUI

/// Title of a thread for autopilot rows: the Summary row's title, else a short id.
@MainActor enum AutopilotTitles {
    static func title(_ summary: SummaryStore, gatewayID: String, targetID: String?, threadID: String?) -> String {
        guard let targetID, let threadID else { return "Zed" }
        let id: String = [gatewayID.lowercased(), targetID, threadID].joined(separator: "\n")
        return summary.entries.first(where: { $0.id == id })?.title ?? "Тред \(threadID.prefix(8))"
    }
}

/// "Автопилот" in Summary: scheduled jobs of every gateway (swipe to cancel), the last log lines
/// and a link to the full history. Hidden when no saved gateway supports `autopilot.status`.
struct AutopilotSummarySection: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var summary: SummaryStore
    @State private var issue = ""

    private struct JobRow: Identifiable {
        let gatewayID: String
        let job: AutopilotJob
        var id: String { gatewayID + "\n" + job.jobID }
    }

    private struct LogRow: Identifiable {
        let gatewayID: String
        let entry: AutopilotLogEntry
        var id: String { gatewayID + "\n" + entry.id }
    }

    private var gateways: [String] { extras.autopilot.keys.sorted() }

    private var jobs: [JobRow] {
        gateways.flatMap { gateway in
            (extras.autopilot[gateway]?.jobs ?? []).map { JobRow(gatewayID: gateway, job: $0) }
        }.sorted { $0.job.at < $1.job.at }
    }

    private var log: [LogRow] {
        let rows: [LogRow] = gateways.flatMap { gateway in
            (extras.autopilot[gateway]?.log ?? []).map { LogRow(gatewayID: gateway, entry: $0) }
        }
        return Array(rows.sorted { $0.entry.at > $1.entry.at }.prefix(5))
    }

    private var disabledEverywhere: Bool {
        !gateways.isEmpty && gateways.allSatisfy { extras.autopilot[$0]?.settings.enabled == false }
    }

    var body: some View {
        if !extras.autopilot.isEmpty {
            Section {
                if jobs.isEmpty {
                    Text(emptyText)
                        .font(.footnote).foregroundStyle(ZLTheme.muted)
                        .listRowBackground(ZLTheme.background)
                }
                ForEach(jobs) { row in
                    jobRow(row)
                        .listRowBackground(ZLTheme.background)
                        .swipeActions(edge: .trailing) {
                            Button("Отменить", role: .destructive) { cancel(row) }
                        }
                }
                if !issue.isEmpty {
                    Text(issue).font(.caption).foregroundStyle(ZLTheme.danger).listRowBackground(ZLTheme.background)
                }
                ForEach(log) { row in
                    logRow(row).listRowBackground(ZLTheme.background)
                }
                NavigationLink(value: SummaryRoute.autopilotHistory) {
                    Label("История автопилота", systemImage: "list.bullet.rectangle.portrait")
                        .font(.footnote)
                }
                .listRowBackground(ZLTheme.background)
                .accessibilityIdentifier("summary-autopilot-history")
            } header: { SectionLabel("Автопилот · \(jobs.count)") }
        }
    }

    private var emptyText: String {
        if disabledEverywhere { return "Автопилот выключен в настройках (Settings › Автопилот)." }
        return "Заданий нет. Автопродолжение включено для тредов по умолчанию; выключить или запланировать продолжение можно в полосе автопилота треда или командой /auto."
    }

    private func jobRow(_ row: JobRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.job.kind == "warm" ? "flame" : "clock.arrow.circlepath")
                .foregroundStyle(ZLTheme.focus).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(AutopilotTitles.title(summary, gatewayID: row.gatewayID, targetID: row.job.targetID, threadID: row.job.threadID))
                    .font(.subheadline.weight(.medium)).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(jobDetail(row.job))
                    .font(.caption).foregroundStyle(ZLTheme.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Смахните влево, чтобы отменить")
        .accessibilityIdentifier("autopilot-job-" + row.job.jobID)
    }

    private func jobDetail(_ job: AutopilotJob) -> String {
        var parts: [String] = [job.kindLabel + " в " + ExtrasFormat.time(job.at), job.reasonLabel]
        if job.attempts > 0 { parts.append("попыток: \(job.attempts)") }
        return parts.joined(separator: " · ")
    }

    private func logRow(_ row: LogRow) -> some View {
        AutopilotLogRow(entry: row.entry,
                        title: AutopilotTitles.title(summary, gatewayID: row.gatewayID, targetID: row.entry.targetID, threadID: row.entry.threadID))
    }

    private func cancel(_ row: JobRow) {
        guard let profile = GatewayExtrasStore.route(gatewayID: row.gatewayID, in: profiles.profiles, preferring: session.profile) else { return }
        issue = ""
        Task {
            do { try await extras.cancel(profile: profile, jobID: row.job.jobID) }
            catch { issue = AutopilotText.failure(error) }
        }
    }
}

/// One log line: action, thread, time, reason and detail code.
struct AutopilotLogRow: View {
    let entry: AutopilotLogEntry
    /// nil inside a thread (the thread is obvious there).
    let title: String?

    private var detail: String {
        var parts: [String] = [ExtrasFormat.time(entry.at)]
        if let reason = entry.reason { parts.append(AutopilotText.reason(reason)) }
        if let detail = entry.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(entry.action == "failed" ? ZLTheme.danger : ZLTheme.muted).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.map { "\(entry.actionLabel) · \($0)" } ?? entry.actionLabel)
                    .font(.caption).foregroundStyle(ZLTheme.ink).lineLimit(2)
                Text(detail).font(.caption2).foregroundStyle(ZLTheme.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The autopilot strip under the thread header (§6.1): status, on/off, "Продолжить в…",
/// "История" and token statistics. Hidden on gateways without `autopilot.status`.
struct AutopilotThreadStrip: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var summary: SummaryStore
    let threadID: String
    let threadTitle: String
    @State private var busy = false
    @State private var issue = ""
    @State private var showingSchedule = false
    @State private var showingHistory = false
    @State private var showingStats = false

    private var status: AutopilotStatus? {
        guard let profile = session.profile else { return nil }
        return extras.autopilotStatus(gatewayID: profile.gatewayID)
    }

    var body: some View {
        if let status, let profile = session.profile, let targetID = session.targetID {
            let state: AutopilotThreadSummary = status.summary(targetID: targetID, threadID: threadID)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: state.active ? "bolt.circle.fill" : "bolt.slash.circle")
                        .foregroundStyle(state.active ? ZLTheme.healthy : ZLTheme.muted)
                    Text(state.statusText).font(.caption.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("autopilot-strip-status")
                    if busy { ProgressView().controlSize(.mini) }
                    Button(state.autoContinue ? "Выключить" : "Включить") {
                        toggle(profile: profile, targetID: targetID, on: !state.autoContinue)
                    }
                    .disabled(busy || session.demoPreview)
                    .accessibilityLabel(state.autoContinue ? "Выключить автопродолжение" : "Включить автопродолжение")
                    .accessibilityIdentifier("autopilot-strip-toggle")
                }
                HStack(spacing: 8) {
                    Button("Продолжить в…") { showingSchedule = true }
                        .accessibilityIdentifier("autopilot-strip-schedule")
                    Button("История") { showingHistory = true }
                        .accessibilityIdentifier("autopilot-strip-history")
                    Button("Токены") { showingStats = true }
                        .accessibilityIdentifier("autopilot-strip-stats")
                    Spacer(minLength: 0)
                }
                .disabled(session.demoPreview)
                if !issue.isEmpty {
                    Text(issue).font(.caption2).foregroundStyle(ZLTheme.danger).lineLimit(3)
                }
            }
            .font(.caption)
            .buttonStyle(.bordered).controlSize(.mini)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(ZLTheme.surface)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("autopilot-strip")
            .sheet(isPresented: $showingSchedule) {
                ContinueAtSheet(threadTitle: threadTitle, defaultText: status.settings.continueText) { date, text in
                    do {
                        try await extras.schedule(profile: profile, targetID: targetID, threadID: threadID, at: date, text: text)
                        await extras.loadThreadNotes(profile: profile, targetID: targetID, threadID: threadID)
                        return nil
                    } catch { return AutopilotText.failure(error) }
                }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack {
                    AutopilotHistoryView(scope: AutopilotHistoryScope(gatewayID: profile.gatewayID, targetID: targetID, threadID: threadID))
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { showingHistory = false } } }
                }
                .environmentObject(extras).environmentObject(summary)
            }
            .sheet(isPresented: $showingStats) {
                NavigationStack {
                    ThreadStatsView(profile: profile, targetID: targetID, threadID: threadID, title: threadTitle)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { showingStats = false } } }
                }
                .environmentObject(extras).environmentObject(session)
            }
            .onChange(of: session.autopilotNote) { _, note in
                // A `/auto …` command changed the autopilot: show the new state.
                guard note != nil else { return }
                Task { await extras.refreshAutopilot(profile) }
            }
        }
    }

    private func toggle(profile: ConnectionProfile, targetID: String, on: Bool) {
        busy = true; issue = ""
        Task {
            defer { busy = false }
            do { try await extras.setAutoContinue(profile: profile, targetID: targetID, threadID: threadID, on: on) }
            catch { issue = AutopilotText.failure(error) }
        }
    }
}

/// Autopilot actions of this thread as small system notes (§6.4). They are never sent to the
/// agent. Transcript entries carry no time, so the notes of the last day follow the messages.
struct AutopilotThreadNotes: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var session: SessionManager
    let threadID: String
    /// Changes when the thread's turn state changes, to reload the notes.
    let trigger: String

    private var notes: [AutopilotLogEntry] {
        guard let profile = session.profile, let targetID = session.targetID else { return [] }
        let since: Date = Date().addingTimeInterval(-24 * 60 * 60)
        let recent: [AutopilotLogEntry] = extras.notes(gatewayID: profile.gatewayID, targetID: targetID, threadID: threadID)
            .filter { $0.at >= since }
        return Array(Array(recent.prefix(3)).reversed())
    }

    private var stopPercent: Int {
        guard let profile = session.profile else { return 98 }
        return extras.autopilotStatus(gatewayID: profile.gatewayID)?.settings.stopPercent ?? 98
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes) { entry in
                Label {
                    Text("\(ExtrasFormat.time(entry.at)) · \(entry.note(stopPercent: stopPercent))")
                } icon: { Image(systemName: entry.symbol) }
                .font(.caption2).foregroundStyle(ZLTheme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("autopilot-note-" + entry.id)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, notes.isEmpty ? 0 : 8)
        .task(id: trigger + "\n" + (session.autopilotNote ?? "")) {
            guard let profile = session.profile, let targetID = session.targetID, !session.demoPreview else { return }
            await extras.loadThreadNotes(profile: profile, targetID: targetID, threadID: threadID)
        }
    }
}

struct AutopilotHistoryScope: Hashable {
    /// nil: every saved gateway that supports the autopilot.
    var gatewayID: String? = nil
    var targetID: String? = nil
    var threadID: String? = nil
}

/// Full autopilot history (`autopilot.history`, newest first, paged by `before`).
struct AutopilotHistoryView: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var summary: SummaryStore
    let scope: AutopilotHistoryScope
    @State private var rows: [Row] = []
    @State private var complete: Set<String> = []
    @State private var loading = false
    @State private var issue = ""

    struct Row: Identifiable, Equatable {
        let gatewayID: String
        let entry: AutopilotLogEntry
        var id: String { gatewayID + "\n" + entry.id }
    }

    private var gateways: [ConnectionProfile] {
        let all: [ConnectionProfile] = GatewayExtrasStore.gateways(profiles.profiles, preferring: session.profile)
        if let gatewayID = scope.gatewayID {
            return all.filter { $0.gatewayID.caseInsensitiveCompare(gatewayID) == .orderedSame }
        }
        return all.filter { extras.autopilotStatus(gatewayID: $0.gatewayID) != nil }
    }

    private var canLoadMore: Bool {
        gateways.contains { !complete.contains($0.gatewayID.lowercased()) }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text(loading ? "Загружаю историю…" : (issue.isEmpty ? "Автопилот ещё ничего не делал." : issue))
                    .font(.subheadline).foregroundStyle(ZLTheme.muted)
            } else if !issue.isEmpty {
                Text(issue).font(.caption).foregroundStyle(ZLTheme.warning)
            }
            ForEach(rows) { row in
                AutopilotLogRow(entry: row.entry,
                                title: scope.threadID == nil
                                    ? AutopilotTitles.title(summary, gatewayID: row.gatewayID, targetID: row.entry.targetID, threadID: row.entry.threadID)
                                    : nil)
            }
            if !rows.isEmpty && canLoadMore {
                Button(loading ? "Загружаю…" : "Показать ещё") { Task { await load(more: true) } }
                    .disabled(loading).font(.footnote)
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(ZLTheme.background)
        .navigationTitle(scope.threadID == nil ? "История автопилота" : "Автопилот в треде")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(more: false) }
        .task { await load(more: false) }
    }

    private func load(more: Bool) async {
        guard !loading else { return }
        loading = true; issue = ""
        defer { loading = false }
        var next: [Row] = more ? rows : []
        var done: Set<String> = more ? complete : []
        for profile in gateways {
            let gateway: String = profile.gatewayID.lowercased()
            guard !done.contains(gateway) else { continue }
            let before: Date? = more ? next.filter { $0.gatewayID == gateway }.map(\.entry.at).min() : nil
            do {
                let page = try await extras.history(profile: profile, targetID: scope.targetID, threadID: scope.threadID,
                                                    before: before, limit: 100)
                let known: Set<String> = Set(next.map(\.id))
                next += page.entries.map { Row(gatewayID: gateway, entry: $0) }.filter { !known.contains($0.id) }
                if page.complete { done.insert(gateway) }
            } catch {
                issue = "\(profile.name): \(AutopilotText.failure(error))"
            }
        }
        rows = next.sorted { $0.entry.at > $1.entry.at }
        complete = done
    }
}

/// "Продолжить в…": a time within the next seven days and an optional text (`autopilot.schedule`).
struct ContinueAtSheet: View {
    @Environment(\.dismiss) private var dismiss
    let threadTitle: String
    let defaultText: String
    let heading: String
    let note: String
    let schedule: (Date, String?) async -> String?
    @State private var date = ContinueAtSheet.defaultDate()
    @State private var text: String
    @State private var busy = false
    @State private var issue = ""

    init(threadTitle: String, defaultText: String, heading: String = "Продолжить в…",
         note: String = "Gateway отправит текст в этот тред в выбранное время; занятый тред поставит его в очередь. Не дальше 7 дней.",
         initialText: String = "", schedule: @escaping (Date, String?) async -> String?) {
        self.threadTitle = threadTitle
        self.defaultText = defaultText
        self.heading = heading
        self.note = note
        self.schedule = schedule
        _text = State(initialValue: initialText)
    }

    private static func defaultDate() -> Date {
        let next = Date().addingTimeInterval(60 * 60)
        let minute = Calendar.current.component(.minute, from: next)
        let rounded = next.addingTimeInterval(TimeInterval(((5 - minute % 5) % 5) * 60))
        return Calendar.current.dateInterval(of: .minute, for: rounded)?.start ?? rounded
    }

    private var range: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(60)...now.addingTimeInterval(7 * 24 * 60 * 60 - 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(threadTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                    DatePicker("Когда", selection: $date, in: range, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("autopilot-continue-at")
                } footer: {
                    Text(note)
                }
                Section("Текст") {
                    TextField(defaultText.isEmpty ? "продолжай" : defaultText, text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("autopilot-continue-text")
                }
                if !issue.isEmpty {
                    Section { Text(issue).foregroundStyle(ZLTheme.danger).font(.footnote) }
                }
            }
            .navigationTitle(heading).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запланировать") { submit() }.disabled(busy)
                        .accessibilityIdentifier("autopilot-schedule")
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func submit() {
        busy = true; issue = ""
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen: Date = date
        Task {
            let failure: String? = await schedule(chosen, trimmed.isEmpty ? nil : trimmed)
            busy = false
            if let failure { issue = failure } else { dismiss() }
        }
    }
}

/// Token statistics of one thread (`stats.thread`, §6.5) and its current context fill.
struct ThreadStatsView: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var session: SessionManager
    let profile: ConnectionProfile
    let targetID: String
    let threadID: String
    let title: String
    @State private var stats: ThreadTokenStats?
    @State private var loading = false
    @State private var issue = ""

    private var context: (used: Int, maximum: Int)? {
        guard session.selectedThreadID == threadID, let settings = session.threadSettings,
              let used = settings.usedTokens, let maximum = settings.maxTokens, maximum > 0 else { return nil }
        return (used, maximum)
    }

    var body: some View {
        List {
            Section {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(3)
            }
            Section("Потрачено токенов") {
                if let stats {
                    LabeledContent("Всего", value: stats.tokens.total.formatted())
                    LabeledContent("Вход", value: stats.tokens.input.formatted())
                    LabeledContent("Выход", value: stats.tokens.output.formatted())
                    LabeledContent("Кэш, чтение", value: stats.tokens.cacheRead.formatted())
                    LabeledContent("Кэш, запись", value: stats.tokens.cacheWrite.formatted())
                    if stats.tokens.thought > 0 {
                        LabeledContent("Размышления (входят в выход)", value: stats.tokens.thought.formatted())
                    }
                    LabeledContent("Ходов", value: stats.turns.formatted())
                    Text(stats.compactions.map { "С учётом сжатий контекста (\($0))." } ?? "С учётом сжатий контекста.")
                        .font(.caption).foregroundStyle(ZLTheme.muted)
                } else if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю…") }
                } else {
                    Text(issue.isEmpty ? "Нет данных." : issue).font(.footnote).foregroundStyle(ZLTheme.muted)
                }
            }
            Section("Контекст сейчас") {
                if let context {
                    LabeledContent("Заполнено", value: "\(context.used.formatted()) / \(context.maximum.formatted())")
                    ProgressView(value: Double(min(context.used, context.maximum)), total: Double(context.maximum))
                } else {
                    Text("Агент не сообщил заполнение контекста.").font(.footnote).foregroundStyle(ZLTheme.muted)
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(ZLTheme.background)
        .navigationTitle("Статистика треда").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true; issue = ""
        defer { loading = false }
        do {
            stats = try await extras.threadStats(profile: profile, targetID: targetID, threadID: threadID)
        } catch {
            issue = GatewayFailure.isUnsupported(error)
                ? "Этот gateway ещё не считает токены тредов."
                : error.localizedDescription
        }
    }
}

/// Settings › Автопилот: every `autopilot.settings` field of one gateway.
struct AutopilotSettingsView: View {
    @EnvironmentObject private var extras: GatewayExtrasStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: SessionManager
    @State private var gatewayID = ""
    @State private var draft = AutopilotSettings()
    @State private var loadedFor = ""
    @State private var busy = false
    @State private var loading = false
    @State private var result = ""
    @State private var failed = false

    private var gateways: [ConnectionProfile] { GatewayExtrasStore.gateways(profiles.profiles, preferring: session.profile) }
    private var profile: ConnectionProfile? {
        GatewayExtrasStore.route(gatewayID: gatewayID, in: profiles.profiles, preferring: session.profile)
    }
    private var status: AutopilotStatus? { gatewayID.isEmpty ? nil : extras.autopilotStatus(gatewayID: gatewayID) }

    var body: some View {
        Form {
            if gateways.count > 1 {
                Section {
                    Picker("Gateway", selection: $gatewayID) {
                        ForEach(gateways) { Text($0.name).tag($0.gatewayID.lowercased()) }
                    }
                }
            }
            if gateways.isEmpty {
                Text("Сначала добавьте подключение в Settings › Connections.").foregroundStyle(ZLTheme.muted)
            } else if status == nil {
                Section {
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Загружаю настройки…") }
                    } else {
                        Text("Этот gateway не отвечает на autopilot.status: он недоступен или ещё не обновлён.")
                            .foregroundStyle(ZLTheme.muted)
                        Button("Повторить") { Task { await load(force: true) } }
                    }
                }
            } else {
                fields
            }
            if !result.isEmpty {
                Section { Text(result).font(.footnote).foregroundStyle(failed ? ZLTheme.danger : ZLTheme.healthy) }
            }
        }
        .scrollContentBackground(.hidden).background(ZLTheme.background)
        .navigationTitle("Автопилот").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
                    .disabled(busy || status == nil || status?.settings == draft)
                    .accessibilityIdentifier("autopilot-settings-save")
            }
        }
        .task {
            if gatewayID.isEmpty { gatewayID = gateways.first?.gatewayID.lowercased() ?? "" }
            await load(force: false)
        }
        .onChange(of: gatewayID) { _, _ in Task { await load(force: false) } }
        .onChange(of: status?.settings) { _, settings in
            // Fill the form once per gateway; later refreshes do not overwrite edits.
            if let settings, loadedFor != gatewayID { draft = settings; loadedFor = gatewayID }
        }
    }

    @ViewBuilder private var fields: some View {
        if draft.hasEnabled {
            Section {
                Toggle("Автопилот включён", isOn: $draft.enabled)
                    .accessibilityIdentifier("autopilot-enabled")
            } footer: {
                Text("Общий выключатель. Автопродолжение включено для каждого треда, пока его не выключить в полосе автопилота треда.")
            }
        }
        Section {
            TextField("продолжай", text: $draft.continueText, axis: .vertical).lineLimit(1...4)
            Stepper("Не больше \(draft.dailyLimit) действий в день на тред", value: $draft.dailyLimit, in: 1...50)
        } header: { Text("Продолжение") } footer: {
            Text("Этот текст отправляется в тред при автопродолжении. Прогрев тоже считается действием.")
        }
        Section {
            Toggle("Запускать закрытый Zed", isOn: $draft.allowZedStart)
            Toggle("Перезапускать зависший Zed", isOn: $draft.allowZedRestart)
        } header: { Text("Zed") } footer: {
            Text("Перезапуск прерывает работающие ходы агентов. Подтверждения инструментов автопилот никогда не даёт сам.")
        }
        Section {
            Stepper("Ждать при использовании ≥ \(draft.holdPercent) %", value: $draft.holdPercent, in: 50...100)
            if draft.hasStopPercent {
                Stepper("Останавливать ход при ≥ \(draft.stopPercent) %", value: $draft.stopPercent, in: 50...100)
            }
            Stepper("…если до сброса больше \(draft.holdMinResetMinutes) мин", value: $draft.holdMinResetMinutes, in: 0...600, step: 5)
        } header: { Text("Бюджет") } footer: {
            Text(draft.hasStopPercent
                 ? "Когда окно лимита почти израсходовано, продолжение откладывается до сброса. У предела остановки gateway прерывает идущие ходы этого агента и продолжит их после сброса."
                 : "Когда окно лимита почти израсходовано, продолжение откладывается до сброса.")
        }
        Section {
            Toggle("Прогревать кэш, пока ждём", isOn: $draft.warmEnabled)
            TextField("Текст прогрева", text: $draft.warmText, axis: .vertical).lineLimit(1...4)
                .disabled(!draft.warmEnabled)
            Stepper("Не реже чем раз в \(draft.warmMaxIntervalMinutes) мин", value: $draft.warmMaxIntervalMinutes, in: 5...300, step: 5)
                .disabled(!draft.warmEnabled)
        } header: { Text("Прогрев") }
        Section {
            Stepper("Агент завис, если нет событий \(draft.stallMinutes) мин", value: $draft.stallMinutes, in: 1...240)
        } header: { Text("Зависание") } footer: {
            Text("Тогда ход останавливается и тред продолжается заново (только при включённом автопродолжении).")
        }
        Section {
            Button("Сбросить к значениям по умолчанию") { draft = draft.resetToDefaults() }.disabled(busy)
        }
    }

    private func load(force: Bool) async {
        guard let profile else { return }
        if status != nil && !force {
            if loadedFor != gatewayID, let settings = status?.settings { draft = settings; loadedFor = gatewayID }
            return
        }
        loading = true
        await extras.refreshAutopilot(profile)
        loading = false
        if let settings = status?.settings, loadedFor != gatewayID { draft = settings; loadedFor = gatewayID }
    }

    private func save() {
        guard let profile, let original = status?.settings else { return }
        busy = true; result = ""; failed = false
        let next: AutopilotSettings = draft
        Task {
            defer { busy = false }
            do {
                draft = try await extras.updateSettings(profile: profile, settings: next, original: original)
                result = "Сохранено на gateway."
            } catch {
                failed = true
                result = AutopilotText.failure(error)
            }
        }
    }
}
