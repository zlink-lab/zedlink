import Foundation
import Combine
import UserNotifications

// Wave 3 gateway-local state (docs/zlink-wave3-contract.md §§ 1–4): unread counts
// (`summary.unread` / `summary.mark_read`), subscription limits (`limits.list`) and the autopilot
// (`autopilot.*`). A gateway that predates a method answers HTTP 403 `UNSUPPORTED_CAPABILITY`; its
// feature is then hidden silently and asked again after a while (gateways update themselves).

enum ExtrasJSON {
    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? { number(value).map { Int($0.rounded()) } }

    static func date(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

enum ExtrasFormat {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    /// "14:30" today, "28 нояб., 14:30" on another day.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clock.string(from: date) : dayClock.string(from: date)
    }

    static func reset(_ date: Date) -> String { "сброс в " + time(date) }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }
}

// MARK: Limits (`limits.list`)

struct LimitWindow: Identifiable, Equatable {
    let kind: String
    let usedPercent: Double
    let resetsAt: Date?
    let status: String?
    /// The window's `resets_at` is in the past; `usedPercent` is 0 until a new observation.
    let reset: Bool

    var id: String { kind }

    init?(_ row: [String: Any]) {
        guard let kind = row["kind"] as? String, !kind.isEmpty else { return nil }
        self.kind = kind
        usedPercent = min(100, max(0, ExtrasJSON.number(row["used_percent"]) ?? 0))
        resetsAt = ExtrasJSON.date(row["resets_at"])
        status = row["status"] as? String
        reset = row["reset"] as? Bool ?? false
    }

    var label: String { Self.label(kind: kind) }

    static func label(kind: String) -> String {
        switch kind {
        case "five_hour": return "5 часов"
        case "seven_day": return "7 дней"
        case "seven_day_opus": return "7 дней · Opus"
        case "seven_day_sonnet": return "7 дней · Sonnet"
        default:
            if kind.hasSuffix("m"), let minutes = Int(kind.dropLast()) {
                return minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes) мин"
            }
            return kind
        }
    }

    var statusLabel: String? {
        let value: String = status ?? ""
        switch value {
        case "": return nil
        case "allowed": return "в норме"
        case "allowed_warning": return "близко к лимиту"
        case "rejected": return "лимит исчерпан"
        default: return value
        }
    }

    /// 0…1 for a progress bar.
    var fraction: Double { usedPercent / 100 }
}

struct AgentLimits: Identifiable, Equatable {
    let agent: String
    let label: String
    let source: String?
    let observedAt: Date?
    let windows: [LimitWindow]

    var id: String { agent }

    init?(_ row: [String: Any]) {
        guard let agent = row["agent"] as? String, !agent.isEmpty else { return nil }
        self.agent = agent
        label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? agent
        source = row["source"] as? String
        observedAt = ExtrasJSON.date(row["observed_at"])
        windows = (row["windows"] as? [[String: Any]] ?? []).compactMap { LimitWindow($0) }
    }

    var sourceLabel: String {
        let value: String = source ?? ""
        switch value {
        case "": return "неизвестно"
        case "acp": return "Claude Agent (ACP)"
        case "codex_rollout": return "журнал Codex"
        default: return value
        }
    }

    /// The window closest to its limit, for the one-line summary.
    var tightest: LimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

struct GatewayLimits: Identifiable, Equatable {
    let gatewayID: String
    let connectionName: String
    let agents: [AgentLimits]
    let fetchedAt: Date

    var id: String { gatewayID.lowercased() }
}

// MARK: Autopilot (`autopilot.*`)

struct AutopilotSettings: Equatable {
    /// Master switch (§6.1). `hasEnabled` / `hasStopPercent`: the gateway reported the field, so
    /// it knows it; older gateways get neither shown nor sent.
    var enabled = true
    var continueText = "продолжай"
    var dailyLimit = 5
    var allowZedStart = true
    var allowZedRestart = false
    var holdPercent = 95
    var stopPercent = 98
    var holdMinResetMinutes = 60
    var warmEnabled = true
    var warmText = "Кратко, одной фразой: на чём остановились? Работу пока не продолжай."
    var warmMaxIntervalMinutes = 55
    var stallMinutes = 15
    var hasEnabled = false
    var hasStopPercent = false

    init() {}

    /// Missing or malformed fields keep the contract defaults.
    init(_ row: [String: Any]) {
        if let value = row["enabled"] as? Bool { enabled = value; hasEnabled = true }
        if let value = row["continue_text"] as? String { continueText = value }
        if let value = ExtrasJSON.int(row["daily_limit"]) { dailyLimit = value }
        if let value = row["allow_zed_start"] as? Bool { allowZedStart = value }
        if let value = row["allow_zed_restart"] as? Bool { allowZedRestart = value }
        if let value = ExtrasJSON.int(row["hold_percent"]) { holdPercent = value }
        if let value = ExtrasJSON.int(row["stop_percent"]) { stopPercent = value; hasStopPercent = true }
        if let value = ExtrasJSON.int(row["hold_min_reset_minutes"]) { holdMinResetMinutes = value }
        if let value = row["warm_enabled"] as? Bool { warmEnabled = value }
        if let value = row["warm_text"] as? String { warmText = value }
        if let value = ExtrasJSON.int(row["warm_max_interval_minutes"]) { warmMaxIntervalMinutes = value }
        if let value = ExtrasJSON.int(row["stall_minutes"]) { stallMinutes = value }
    }

    /// Defaults, keeping which optional fields this gateway knows.
    func resetToDefaults() -> AutopilotSettings {
        var defaults = AutopilotSettings()
        defaults.hasEnabled = hasEnabled
        defaults.hasStopPercent = hasStopPercent
        return defaults
    }

    var payload: [String: Any] {
        var result: [String: Any] = [
            "continue_text": continueText,
            "daily_limit": dailyLimit,
            "allow_zed_start": allowZedStart,
            "allow_zed_restart": allowZedRestart,
            "hold_percent": holdPercent,
            "hold_min_reset_minutes": holdMinResetMinutes,
            "warm_enabled": warmEnabled,
            "warm_text": warmText,
            "warm_max_interval_minutes": warmMaxIntervalMinutes,
            "stall_minutes": stallMinutes,
        ]
        if hasEnabled { result["enabled"] = enabled }
        if hasStopPercent { result["stop_percent"] = stopPercent }
        return result
    }

    /// `autopilot.settings` takes partial settings: only the fields that differ from `old`.
    func changes(from old: AutopilotSettings) -> [String: Any] {
        let mine: [String: Any] = payload
        let theirs: [String: Any] = old.payload
        var result: [String: Any] = [:]
        for (key, value) in mine {
            guard let previous = theirs[key], Self.same(value, previous) else { result[key] = value; continue }
        }
        return result
    }

    private static func same(_ left: Any, _ right: Any) -> Bool {
        if let left = left as? String, let right = right as? String { return left == right }
        if let left = left as? Bool, let right = right as? Bool { return left == right }
        if let left = left as? Int, let right = right as? Int { return left == right }
        return false
    }
}

struct AutopilotJob: Identifiable, Equatable {
    let jobID: String
    let targetID: String
    let threadID: String
    let kind: String
    let at: Date
    let text: String?
    let reason: String
    let attempts: Int

    var id: String { jobID }

    /// Reasons of jobs that wait for a subscription window to reset.
    static let resetReasons: Set<String> = ["rate_limit", "budget_hold", "hard_stop", "stop_percent", "stopped"]

    init?(_ row: [String: Any]) {
        guard let jobID = ExtrasJSON.text(row["job_id"]), let targetID = row["target_id"] as? String,
              let threadID = row["thread_id"] as? String, let at = ExtrasJSON.date(row["at"]) else { return nil }
        self.jobID = jobID
        self.targetID = targetID
        self.threadID = threadID
        self.at = at
        kind = row["kind"] as? String ?? "continue"
        text = row["text"] as? String
        reason = row["reason"] as? String ?? "user"
        attempts = ExtrasJSON.int(row["attempts"]) ?? 0
    }

    var kindLabel: String { kind == "warm" ? "Прогрев" : "Продолжение" }

    var waitsForReset: Bool { Self.resetReasons.contains(reason) }

    var reasonLabel: String { AutopilotText.reason(reason) }
}

struct AutopilotThreadState: Equatable {
    let targetID: String
    let threadID: String
    let autoContinue: Bool
    let actionsToday: Int

    init?(_ row: [String: Any]) {
        guard let targetID = row["target_id"] as? String, let threadID = row["thread_id"] as? String else { return nil }
        self.targetID = targetID
        self.threadID = threadID
        // §6.1: on unless explicitly switched off.
        autoContinue = row["auto_continue"] as? Bool ?? true
        actionsToday = ExtrasJSON.int(row["actions_today"]) ?? 0
    }
}

/// One autopilot action (`autopilot.status` `log`, `autopilot.history` rows). Codes only, never
/// transcript text.
struct AutopilotLogEntry: Identifiable, Equatable {
    let at: Date
    let targetID: String?
    let threadID: String?
    let action: String
    let reason: String?
    let detail: String?
    let id: String

    init?(_ row: [String: Any], index: Int) {
        guard let at = ExtrasJSON.date(row["at"]), let action = row["action"] as? String else { return nil }
        let thread: String? = row["thread_id"] as? String
        let detailCode: String? = (row["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.at = at
        self.action = action
        targetID = row["target_id"] as? String
        threadID = thread
        reason = (row["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        detail = detailCode
        let rowID: String? = ExtrasJSON.text(row["id"]) ?? ExtrasJSON.text(row["log_id"])
        id = rowID ?? [String(Int(at.timeIntervalSince1970)), action, thread ?? "", detailCode ?? "", String(index)].joined(separator: ":")
    }

    var actionLabel: String {
        switch action {
        case "continued": return "Продолжил"
        case "warmed": return "Прогрел"
        case "deferred": return "Отложил"
        case "skipped": return "Пропустил"
        case "zed_started": return "Запустил Zed"
        case "zed_restarted": return "Перезапустил Zed"
        case "stall_cancelled": return "Остановил зависший ход"
        case "stopped", "hard_stop", "cancelled_turn": return "Остановил ход"
        case "dropped": return "Снял задание"
        case "scheduled": return "Запланировал"
        case "failed": return "Ошибка"
        default: return action
        }
    }

    /// "Автопилот: продолжил после сброса лимита" — the note shown inside the thread.
    func note(stopPercent: Int) -> String {
        let why: String = reason ?? ""
        let text: String
        switch action {
        case "continued":
            switch why {
            case "rate_limit", "budget_hold", "hard_stop", "stop_percent", "stopped": text = "продолжил после сброса лимита"
            case "max_turn_requests": text = "продолжил после лимита запросов хода"
            case "stalled": text = "продолжил после зависания"
            case "user": text = "продолжил по расписанию"
            default: text = "продолжил"
            }
        case "warmed": text = "прогрел кэш, пока ждём сброса"
        case "deferred": text = why.isEmpty ? "отложил продолжение" : "отложил продолжение (\(AutopilotText.reason(why)))"
        case "skipped": text = "пропустил продолжение" + (detail.map { " (\($0))" } ?? "")
        case "zed_started": text = "запустил Zed"
        case "zed_restarted": text = "перезапустил зависший Zed"
        case "stall_cancelled": text = "остановил зависший ход"
        case "stopped", "hard_stop", "cancelled_turn":
            text = "остановил на \(Self.percent(in: detail) ?? stopPercent) %"
        case "dropped": text = "снял задание" + (detail.map { " (\($0))" } ?? "")
        case "scheduled": text = "запланировал продолжение"
        case "failed": text = "ошибка" + (detail.map { " (\($0))" } ?? "")
        default: text = action + (detail.map { " (\($0))" } ?? "")
        }
        return "Автопилот: " + text
    }

    /// A percentage in a detail code such as `used 98.4` or `98`.
    private static func percent(in detail: String?) -> Int? {
        guard let detail else { return nil }
        let digits: String = String(detail.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "." }))
        guard let value = Double(digits), (1...100).contains(value) else { return nil }
        return Int(value.rounded())
    }

    var symbol: String {
        switch action {
        case "continued": return "play.circle"
        case "warmed": return "flame"
        case "deferred", "scheduled": return "clock"
        case "skipped", "dropped": return "forward"
        case "zed_started", "zed_restarted": return "power"
        case "stopped", "hard_stop", "cancelled_turn", "stall_cancelled": return "stop.circle"
        case "failed": return "exclamationmark.triangle"
        default: return "circle"
        }
    }
}

struct AutopilotStatus: Equatable {
    var settings: AutopilotSettings
    var jobs: [AutopilotJob]
    var threads: [AutopilotThreadState]
    var log: [AutopilotLogEntry]

    init(_ result: [String: Any]) {
        settings = AutopilotSettings(result["settings"] as? [String: Any] ?? [:])
        jobs = (result["jobs"] as? [[String: Any]] ?? []).compactMap { AutopilotJob($0) }.sorted { $0.at < $1.at }
        threads = (result["threads"] as? [[String: Any]] ?? []).compactMap { AutopilotThreadState($0) }
        let rows: [[String: Any]] = result["log"] as? [[String: Any]] ?? []
        log = rows.enumerated().compactMap { AutopilotLogEntry($0.element, index: $0.offset) }.sorted { $0.at > $1.at }
    }

    func thread(targetID: String, threadID: String) -> AutopilotThreadState? {
        threads.first { $0.targetID == targetID && $0.threadID == threadID }
    }

    func jobs(targetID: String, threadID: String) -> [AutopilotJob] {
        jobs.filter { $0.targetID == targetID && $0.threadID == threadID }
    }

    /// The state the thread strip shows. A thread without a record is on (§6.1).
    func summary(targetID: String, threadID: String) -> AutopilotThreadSummary {
        let record: AutopilotThreadState? = thread(targetID: targetID, threadID: threadID)
        return AutopilotThreadSummary(globallyEnabled: settings.enabled,
                                      autoContinue: record?.autoContinue ?? true,
                                      nextJob: jobs(targetID: targetID, threadID: threadID).first,
                                      actionsToday: record?.actionsToday ?? 0,
                                      dailyLimit: settings.dailyLimit)
    }
}

struct AutopilotThreadSummary: Equatable {
    let globallyEnabled: Bool
    let autoContinue: Bool
    let nextJob: AutopilotJob?
    let actionsToday: Int
    let dailyLimit: Int

    var active: Bool { globallyEnabled && autoContinue }

    /// "Автопилот: вкл / выкл / ждёт сброса до 14:30 / задание в 15:00".
    var statusText: String {
        if let job = nextJob {
            let when: String = ExtrasFormat.time(job.at)
            let base: String = job.waitsForReset ? "Автопилот: ждёт сброса до " + when : "Автопилот: задание в " + when
            return globallyEnabled ? base : base + " · выключен в настройках"
        }
        if !globallyEnabled { return "Автопилот: выкл (в настройках)" }
        return autoContinue ? "Автопилот: вкл" : "Автопилот: выкл"
    }
}

/// `/auto …` typed on the phone is handled by the gateway itself (§3): HTTP 200 with
/// `result.intercepted == "autopilot"` and a `message`; nothing reached the agent.
enum AutopilotInterception {
    static func message(in result: [String: Any]) -> String? {
        guard result["intercepted"] as? String == "autopilot" else { return nil }
        let text: String = (result["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Команда автопилота выполнена." : text
    }
}

enum AutopilotText {
    static func reason(_ code: String) -> String {
        switch code {
        case "user": return "вручную"
        case "rate_limit": return "после лимита"
        case "max_turn_requests": return "лимит запросов хода"
        case "stalled": return "агент завис"
        case "budget_hold": return "ждёт сброса лимита"
        case "hard_stop", "stop_percent", "stopped": return "остановлен у предела лимита"
        case "warm": return "прогрев кэша"
        default: return code
        }
    }

    static func failure(_ error: Error) -> String {
        if GatewayFailure.isUnsupported(error) { return "Автопилот не поддерживается этим gateway." }
        if case GatewayFailure.native(let code) = error {
            switch code {
            case "INVALID_REQUEST": return "Gateway не принял значение (INVALID_REQUEST). Проверьте время и поля."
            case "NOT_FOUND", "UNKNOWN_JOB": return "Задание уже выполнено или отменено."
            default: break
            }
        }
        return error.localizedDescription
    }
}

// MARK: Token statistics (`stats.thread`, `stats.usage`, `stats.limits`)

/// Token counts by kind. Field names follow the bridge `usage` (`input_tokens`, …); the short
/// SQLite column names (`input`, …) are accepted too.
struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var thought = 0
    /// The gateway's own total when it sends one.
    var reportedTotal: Int? = nil

    init() {}

    init(_ row: [String: Any]) {
        let source: [String: Any] = row["tokens"] as? [String: Any] ?? row["usage"] as? [String: Any] ?? row
        input = Self.value(source, ["input_tokens", "input"])
        output = Self.value(source, ["output_tokens", "output"])
        cacheRead = Self.value(source, ["cache_read_tokens", "cache_read", "cached_read_tokens"])
        cacheWrite = Self.value(source, ["cache_write_tokens", "cache_write", "cached_write_tokens"])
        thought = Self.value(source, ["thought_tokens", "thought"])
        reportedTotal = ["total_tokens", "total"].lazy.compactMap { ExtrasJSON.int(source[$0]) }.first
    }

    private static func value(_ row: [String: Any], _ keys: [String]) -> Int {
        for key in keys { if let value = ExtrasJSON.int(row[key]) { return max(0, value) } }
        return 0
    }

    /// Thought tokens are shown on their own: agents count them inside `output`.
    var total: Int { reportedTotal ?? (input + output + cacheRead + cacheWrite) }

    static func + (left: TokenCounts, right: TokenCounts) -> TokenCounts {
        var sum = TokenCounts()
        sum.input = left.input + right.input
        sum.output = left.output + right.output
        sum.cacheRead = left.cacheRead + right.cacheRead
        sum.cacheWrite = left.cacheWrite + right.cacheWrite
        sum.thought = left.thought + right.thought
        if let a = left.reportedTotal, let b = right.reportedTotal { sum.reportedTotal = a + b }
        return sum
    }
}

enum TokenFormat {
    /// 1 234 567 → "1,2 млн"; small values in full.
    static func short(_ value: Int) -> String {
        let number = Double(value)
        if value >= 1_000_000 { return String(format: "%.1f млн", number / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if value >= 10_000 { return "\(Int((number / 1000).rounded())) тыс." }
        return value.formatted()
    }
}

struct ThreadTokenStats: Equatable {
    let tokens: TokenCounts
    let turns: Int
    let compactions: Int?

    init(_ result: [String: Any]) {
        let totals: [String: Any] = result["totals"] as? [String: Any] ?? result
        tokens = TokenCounts(totals)
        turns = ExtrasJSON.int(totals["turns"]) ?? ExtrasJSON.int(result["turns"]) ?? 0
        compactions = ExtrasJSON.int(totals["compactions"]) ?? ExtrasJSON.int(result["compactions"])
            ?? ExtrasJSON.int(result["compaction_turns"])
    }
}

struct UsageDay: Identifiable, Equatable {
    let day: Date
    let agent: String
    let tokens: TokenCounts
    let turns: Int
    var id: String { "\(Int(day.timeIntervalSince1970)):\(agent)" }
}

struct UsageThread: Identifiable, Equatable {
    let targetID: String
    let threadID: String
    let agent: String?
    let tokens: TokenCounts
    let turns: Int
    var id: String { targetID + "\n" + threadID }
}

struct UsageStats: Equatable {
    let days: [UsageDay]
    let threads: [UsageThread]

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ value: Any?) -> Date? {
        if let text = value as? String { return dayFormat.date(from: String(text.prefix(10))) }
        return ExtrasJSON.date(value)
    }

    /// `days`: rows per day and agent, or per day with an `agents` list. `threads` (or
    /// `top_threads`): the top threads of the range.
    init(_ result: [String: Any]) {
        var days: [UsageDay] = []
        for row in result["days"] as? [[String: Any]] ?? result["usage"] as? [[String: Any]] ?? [] {
            guard let day = Self.day(row["day"] ?? row["date"] ?? row["at"]) else { continue }
            if let agents = row["agents"] as? [[String: Any]] {
                for agent in agents {
                    days.append(UsageDay(day: day, agent: agent["agent"] as? String ?? "?", tokens: TokenCounts(agent),
                                         turns: ExtrasJSON.int(agent["turns"]) ?? 0))
                }
            } else {
                days.append(UsageDay(day: day, agent: row["agent"] as? String ?? "?", tokens: TokenCounts(row),
                                     turns: ExtrasJSON.int(row["turns"]) ?? 0))
            }
        }
        self.days = days.sorted { $0.day < $1.day }
        threads = (result["threads"] as? [[String: Any]] ?? result["top_threads"] as? [[String: Any]] ?? []).compactMap { row in
            guard let target = row["target_id"] as? String ?? row["target"] as? String,
                  let thread = row["thread_id"] as? String ?? row["thread"] as? String else { return nil }
            return UsageThread(targetID: target, threadID: thread, agent: row["agent"] as? String,
                               tokens: TokenCounts(row), turns: ExtrasJSON.int(row["turns"]) ?? 0)
        }.sorted { $0.tokens.total > $1.tokens.total }
    }

    var agents: [String] { Array(Set(days.map(\.agent))).sorted() }

    func totals(agent: String) -> (tokens: TokenCounts, turns: Int) {
        var tokens = TokenCounts()
        var turns = 0
        for day in days where day.agent == agent {
            tokens = tokens + day.tokens
            turns += day.turns
        }
        return (tokens, turns)
    }
}

struct LimitSample: Identifiable, Equatable {
    let kind: String
    let at: Date
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { "\(kind):\(at.timeIntervalSince1970)" }

    init?(_ row: [String: Any]) {
        guard let at = ExtrasJSON.date(row["at"]), let used = ExtrasJSON.number(row["used_percent"]) else { return nil }
        kind = row["kind"] as? String ?? "?"
        self.at = at
        usedPercent = min(100, max(0, used))
        resetsAt = ExtrasJSON.date(row["resets_at"])
    }

    static func list(_ result: [String: Any]) -> [LimitSample] {
        (result["samples"] as? [[String: Any]] ?? result["points"] as? [[String: Any]] ?? [])
            .compactMap { LimitSample($0) }.sorted { $0.at < $1.at }
    }
}

// MARK: Store

@MainActor final class GatewayExtrasStore: ObservableObject {
    /// `SummaryEntry.id` (gateway lowercased, target, thread) → unread agent events.
    @Published private(set) var unread: [String: Int] = [:]
    /// Lowercased gateway id → `total` of `summary.unread`; only gateways that support it.
    @Published private(set) var unreadTotals: [String: Int] = [:]
    @Published private(set) var limits: [GatewayLimits] = []
    @Published private(set) var limitsRefreshing = false
    /// Connection name → why its limits could not be refreshed (last known values stay).
    @Published private(set) var limitsIssues: [String: String] = [:]
    /// Lowercased gateway id → `autopilot.status`; only gateways that support it.
    @Published private(set) var autopilot: [String: AutopilotStatus] = [:]
    /// Connection name per lowercased gateway id, for section headers.
    @Published private(set) var connectionNames: [String: String] = [:]
    /// `SummaryEntry.id`-style key → latest autopilot actions of that thread (newest first).
    @Published private(set) var threadNotes: [String: [AutopilotLogEntry]] = [:]

    private var unsupportedUntil: [String: Date] = [:]
    private var markTasks: [String: Task<Void, Never>] = [:]
    private var lastMarked: [String: Date] = [:]
    private var refreshingAll = false
    private let recheckUnsupported: TimeInterval = 15 * 60

    var unreadTotal: Int { unreadTotals.values.reduce(0, +) }

    func unreadCount(_ entryID: String) -> Int { unread[entryID] ?? 0 }

    func autopilotStatus(gatewayID: String) -> AutopilotStatus? { autopilot[gatewayID.lowercased()] }

    var allLimitAgents: Int { limits.reduce(0) { $0 + $1.agents.count } }

    // MARK: Support memory

    private func key(_ gateway: String, _ feature: String) -> String { gateway.lowercased() + "\n" + feature }

    private func isUnsupported(_ gateway: String, _ feature: String) -> Bool {
        guard let until = unsupportedUntil[key(gateway, feature)] else { return false }
        return until > Date()
    }

    private func markUnsupported(_ gateway: String, _ feature: String) {
        unsupportedUntil[key(gateway, feature)] = Date().addingTimeInterval(recheckUnsupported)
    }

    private func markSupported(_ gateway: String, _ feature: String) {
        unsupportedUntil[key(gateway, feature)] = nil
    }

    /// One saved route per gateway id (the first one; its main/mesh addresses are tried by
    /// `GatewayClient`), preferring `current`.
    static func gateways(_ profiles: [ConnectionProfile], preferring current: ConnectionProfile? = nil) -> [ConnectionProfile] {
        var seen: Set<String> = []
        var result: [ConnectionProfile] = []
        let ordered: [ConnectionProfile] = (current.map { [$0] } ?? []) + profiles
        for profile in ordered {
            let gateway: String = profile.gatewayID.lowercased()
            guard profiles.contains(where: { $0.id == profile.id }), !seen.contains(gateway) else { continue }
            seen.insert(gateway)
            result.append(profile)
        }
        return result
    }

    static func route(gatewayID: String, in profiles: [ConnectionProfile], preferring current: ConnectionProfile?) -> ConnectionProfile? {
        if let current, current.gatewayID.caseInsensitiveCompare(gatewayID) == .orderedSame,
           profiles.contains(where: { $0.id == current.id }) { return current }
        return profiles.first { $0.gatewayID.caseInsensitiveCompare(gatewayID) == .orderedSame }
    }

    private func makeClient(_ profile: ConnectionProfile) async throws -> GatewayClient {
        guard let token = await CredentialVault.shared.read(profile) else { throw GatewayFailure.native("Pair this device first.") }
        return GatewayClient(profile: profile, token: token)
    }

    // MARK: Refresh

    /// Unread, limits and autopilot of every saved gateway. Failures keep the last known values.
    func refresh(profiles: [ConnectionProfile], preferring current: ConnectionProfile? = nil) async {
        guard !refreshingAll else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        let routes: [ConnectionProfile] = Self.gateways(profiles, preferring: current)
        forget(except: routes)
        for profile in routes {
            connectionNames[profile.gatewayID.lowercased()] = profile.name
            guard let client = try? await makeClient(profile) else { continue }
            await loadUnread(profile, client: client)
            await loadLimits(profile, client: client)
            await loadAutopilot(profile, client: client)
        }
        await applyBadge()
    }

    /// Only `summary.unread` (foreground, tab badge).
    func refreshUnread(profiles: [ConnectionProfile], preferring current: ConnectionProfile? = nil) async {
        let routes: [ConnectionProfile] = Self.gateways(profiles, preferring: current)
        forget(except: routes)
        for profile in routes {
            guard let client = try? await makeClient(profile) else { continue }
            await loadUnread(profile, client: client)
        }
        await applyBadge()
    }

    func refreshLimits(profiles: [ConnectionProfile], preferring current: ConnectionProfile? = nil) async {
        guard !limitsRefreshing else { return }
        limitsRefreshing = true
        defer { limitsRefreshing = false }
        for profile in Self.gateways(profiles, preferring: current) {
            do {
                let client = try await makeClient(profile)
                await loadLimits(profile, client: client)
            } catch {
                limitsIssues[profile.name] = error.localizedDescription
            }
        }
    }

    func refreshAutopilot(_ profile: ConnectionProfile) async {
        guard let client = try? await makeClient(profile) else { return }
        await loadAutopilot(profile, client: client)
    }

    /// Drops values of gateways that are no longer saved.
    private func forget(except routes: [ConnectionProfile]) {
        let kept: Set<String> = Set(routes.map { $0.gatewayID.lowercased() })
        unread = unread.filter { kept.contains(String($0.key.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")) }
        unreadTotals = unreadTotals.filter { kept.contains($0.key) }
        limits.removeAll { !kept.contains($0.id) }
        autopilot = autopilot.filter { kept.contains($0.key) }
    }

    private func loadUnread(_ profile: ConnectionProfile, client: GatewayClient) async {
        let gateway: String = profile.gatewayID.lowercased()
        guard !isUnsupported(gateway, "unread") else { return }
        do {
            let result = try await client.rpc("summary.unread")
            markSupported(gateway, "unread")
            var next: [String: Int] = unread.filter { !$0.key.hasPrefix(gateway + "\n") }
            for row in result["threads"] as? [[String: Any]] ?? [] {
                guard let target = row["target_id"] as? String, let thread = row["thread_id"] as? String,
                      let count = ExtrasJSON.int(row["unread"]), count > 0 else { continue }
                next[[gateway, target, thread].joined(separator: "\n")] = count
            }
            // A thread open on screen stays read even if the reply raced a newer event.
            for pending in markTasks.keys where pending.hasPrefix(gateway + "\n") { next[pending] = nil }
            unread = next
            unreadTotals[gateway] = ExtrasJSON.int(result["total"]) ?? next.filter { $0.key.hasPrefix(gateway + "\n") }.values.reduce(0, +)
        } catch {
            if GatewayFailure.isUnsupported(error) {
                markUnsupported(gateway, "unread")
                unread = unread.filter { !$0.key.hasPrefix(gateway + "\n") }
                unreadTotals[gateway] = nil
            }
            // Unreachable: keep the last known counts.
        }
    }

    private func loadLimits(_ profile: ConnectionProfile, client: GatewayClient) async {
        let gateway: String = profile.gatewayID.lowercased()
        guard !isUnsupported(gateway, "limits") else { return }
        do {
            let result = try await client.rpc("limits.list")
            markSupported(gateway, "limits")
            let agents: [AgentLimits] = (result["agents"] as? [[String: Any]] ?? []).compactMap { AgentLimits($0) }
            let entry = GatewayLimits(gatewayID: profile.gatewayID, connectionName: profile.name, agents: agents, fetchedAt: Date())
            if let index = limits.firstIndex(where: { $0.id == gateway }) { limits[index] = entry }
            else { limits.append(entry) }
            limitsIssues[profile.name] = nil
        } catch {
            if GatewayFailure.isUnsupported(error) {
                markUnsupported(gateway, "limits")
                limits.removeAll { $0.id == gateway }
                limitsIssues[profile.name] = nil
            } else if limits.contains(where: { $0.id == gateway }) {
                limitsIssues[profile.name] = error.localizedDescription
            }
        }
    }

    private func loadAutopilot(_ profile: ConnectionProfile, client: GatewayClient) async {
        let gateway: String = profile.gatewayID.lowercased()
        guard !isUnsupported(gateway, "autopilot") else { return }
        do {
            let result = try await client.rpc("autopilot.status")
            markSupported(gateway, "autopilot")
            autopilot[gateway] = AutopilotStatus(result)
        } catch {
            if GatewayFailure.isUnsupported(error) {
                markUnsupported(gateway, "autopilot")
                autopilot[gateway] = nil
            }
        }
    }

    // MARK: Read marks

    /// `summary.mark_read` for a thread on screen: at once, then at most every three seconds
    /// while new events arrive.
    func markRead(profile: ConnectionProfile, targetID: String, threadID: String) {
        let gateway: String = profile.gatewayID.lowercased()
        guard !isUnsupported(gateway, "unread") else { return }
        let entry: String = [gateway, targetID, threadID].joined(separator: "\n")
        if let count = unread[entry] {
            unread[entry] = nil
            if let total = unreadTotals[gateway] { unreadTotals[gateway] = max(0, total - count) }
        }
        guard markTasks[entry] == nil else { return }
        let wait: TimeInterval = max(0, 3 - Date().timeIntervalSince(lastMarked[entry] ?? .distantPast))
        markTasks[entry] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            await self.sendMarkRead(profile: profile, targetID: targetID, threadID: threadID, entry: entry)
        }
    }

    private func sendMarkRead(profile: ConnectionProfile, targetID: String, threadID: String, entry: String) async {
        let gateway: String = profile.gatewayID.lowercased()
        defer { markTasks[entry] = nil; lastMarked[entry] = Date() }
        do {
            let client = try await makeClient(profile)
            let result = try await client.rpc("summary.mark_read", params: ["target_id": targetID, "thread_id": threadID])
            markSupported(gateway, "unread")
            unread[entry] = nil
            if let total = ExtrasJSON.int(result["total"]) { unreadTotals[gateway] = total }
            await applyBadge()
        } catch {
            if GatewayFailure.isUnsupported(error) {
                markUnsupported(gateway, "unread")
                unreadTotals[gateway] = nil
                await applyBadge()
            }
        }
    }

    /// The app icon badge follows `summary.unread` when at least one gateway supports it;
    /// otherwise APNs `aps.badge` alone sets it.
    private func applyBadge() async {
        guard !unreadTotals.isEmpty else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(unreadTotal)
    }

    // MARK: Autopilot actions

    @discardableResult
    func schedule(profile: ConnectionProfile, targetID: String, threadID: String, at: Date, text: String?) async throws -> AutopilotJob? {
        var params: [String: Any] = ["target_id": targetID, "thread_id": threadID, "at": Int(at.timeIntervalSince1970.rounded())]
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { params["text"] = text }
        let result = try await makeClient(profile).rpc("autopilot.schedule", params: params)
        await refreshAutopilot(profile)
        return (result["job"] as? [String: Any]).flatMap { AutopilotJob($0) }
    }

    func cancel(profile: ConnectionProfile, jobID: String) async throws {
        let gateway: String = profile.gatewayID.lowercased()
        // The row leaves at once; a failure brings it back with the refresh below.
        autopilot[gateway]?.jobs.removeAll { $0.jobID == jobID }
        defer { Task { [weak self] in await self?.refreshAutopilot(profile) } }
        _ = try await makeClient(profile).rpc("autopilot.cancel", params: ["job_id": jobID])
    }

    func setAutoContinue(profile: ConnectionProfile, targetID: String, threadID: String, on: Bool) async throws {
        _ = try await makeClient(profile).rpc("autopilot.thread", params: ["target_id": targetID, "thread_id": threadID, "auto_continue": on])
        await refreshAutopilot(profile)
    }

    /// Sends only the fields that differ from `original` (the gateway's current values).
    func updateSettings(profile: ConnectionProfile, settings: AutopilotSettings, original: AutopilotSettings) async throws -> AutopilotSettings {
        let changes: [String: Any] = settings.changes(from: original)
        guard !changes.isEmpty else { return original }
        let result = try await makeClient(profile).rpc("autopilot.settings", params: changes)
        let saved = AutopilotSettings(result["settings"] as? [String: Any] ?? settings.payload)
        autopilot[profile.gatewayID.lowercased()]?.settings = saved
        return saved
    }

    // MARK: Autopilot history (§6.4)

    /// Whether the last call of `feature` on this gateway answered UNSUPPORTED_CAPABILITY.
    func isFeatureUnsupported(gatewayID: String, _ feature: String) -> Bool { isUnsupported(gatewayID.lowercased(), feature) }

    /// `autopilot.history`, newest first. Gateways without it: the `autopilot.status` log (last 50).
    func history(profile: ConnectionProfile, targetID: String?, threadID: String?, before: Date? = nil,
                 limit: Int = 100) async throws -> (entries: [AutopilotLogEntry], complete: Bool) {
        let gateway: String = profile.gatewayID.lowercased()
        if !isUnsupported(gateway, "history") {
            var params: [String: Any] = ["limit": min(200, max(1, limit))]
            if let targetID { params["target_id"] = targetID }
            if let threadID { params["thread_id"] = threadID }
            if let before { params["before"] = Int(before.timeIntervalSince1970.rounded(.down)) }
            do {
                let result = try await makeClient(profile).rpc("autopilot.history", params: params)
                markSupported(gateway, "history")
                let rows: [[String: Any]] = result["rows"] as? [[String: Any]] ?? result["history"] as? [[String: Any]]
                    ?? result["log"] as? [[String: Any]] ?? result["entries"] as? [[String: Any]] ?? []
                let entries: [AutopilotLogEntry] = rows.enumerated()
                    .compactMap { AutopilotLogEntry($0.element, index: $0.offset) }.sorted { $0.at > $1.at }
                return (entries, entries.count < limit)
            } catch {
                guard GatewayFailure.isUnsupported(error) else { throw error }
                markUnsupported(gateway, "history")
            }
        }
        await refreshAutopilot(profile)
        let log: [AutopilotLogEntry] = (autopilot[gateway]?.log ?? []).filter { entry in
            (targetID == nil || entry.targetID == targetID) && (threadID == nil || entry.threadID == threadID)
                && (before == nil || entry.at < before!)
        }
        return (log, true)
    }

    /// The latest autopilot actions of one thread, shown as notes inside it.
    func loadThreadNotes(profile: ConnectionProfile, targetID: String, threadID: String) async {
        let gateway: String = profile.gatewayID.lowercased()
        guard autopilot[gateway] != nil || !isUnsupported(gateway, "history") else { return }
        let entry: String = [gateway, targetID, threadID].joined(separator: "\n")
        guard let loaded = try? await history(profile: profile, targetID: targetID, threadID: threadID, limit: 20) else { return }
        threadNotes[entry] = Array(loaded.entries.prefix(20))
    }

    func notes(gatewayID: String, targetID: String, threadID: String) -> [AutopilotLogEntry] {
        threadNotes[[gatewayID.lowercased(), targetID, threadID].joined(separator: "\n")] ?? []
    }

    // MARK: Statistics (§6.5, §6.6)

    private func stats(_ method: String, feature: String, profile: ConnectionProfile,
                       params: [String: Any]) async throws -> [String: Any] {
        let gateway: String = profile.gatewayID.lowercased()
        guard !isUnsupported(gateway, feature) else { throw GatewayFailure.native("UNSUPPORTED_CAPABILITY") }
        do {
            let result = try await makeClient(profile).rpc(method, params: params)
            markSupported(gateway, feature)
            return result
        } catch {
            if GatewayFailure.isUnsupported(error) { markUnsupported(gateway, feature) }
            throw error
        }
    }

    func threadStats(profile: ConnectionProfile, targetID: String, threadID: String) async throws -> ThreadTokenStats {
        ThreadTokenStats(try await stats("stats.thread", feature: "stats.thread", profile: profile,
                                         params: ["target_id": targetID, "thread_id": threadID]))
    }

    func usageStats(profile: ConnectionProfile, days: Int) async throws -> UsageStats {
        UsageStats(try await stats("stats.usage", feature: "stats.usage", profile: profile,
                                   params: ["days": min(90, max(1, days))]))
    }

    func limitSamples(profile: ConnectionProfile, agent: String, hours: Int) async throws -> [LimitSample] {
        LimitSample.list(try await stats("stats.limits", feature: "stats.limits", profile: profile,
                                         params: ["agent": agent, "hours": min(168, max(1, hours))]))
    }
}
