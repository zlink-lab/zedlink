import Foundation

/// `zed.status` from the gateway. Zed control is gateway-level: it is not advertised in
/// `instance.info.capabilities`, and gateways without it answer `UNSUPPORTED_CAPABILITY`.
struct ZedControlStatus: Equatable {
    /// The gateway has a systemd unit for this target, so `zed.start` / `zed.restart` work.
    var control: Bool
    /// `up`, `hung` or `down`.
    var bridge: String
    var instanceID: String?
    var epoch: String?
    var generating: Int
    var restarting: Bool
    /// Staged Zed release (gateway `zed_update`); nil on gateways without it.
    var update: ZedUpdateStatus?

    init?(_ result: [String: Any]) {
        guard let bridge = result["bridge"] as? String else { return nil }
        self.bridge = bridge
        control = result["control"] as? Bool ?? false
        instanceID = Self.text(result["instance_id"])
        epoch = Self.text(result["epoch"])
        generating = result["generating"] as? Int ?? 0
        restarting = result["restarting"] as? Bool ?? false
        update = (result["update"] as? [String: Any]).map(ZedUpdateStatus.init)
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

/// `zed.status.update`: a release staged by `zed-zlink-update` waits until every thread stops.
struct ZedUpdateStatus: Equatable {
    var installedTag: String?
    var pendingTag: String?
    var waiting: String?
    var applying: Bool
    var lastResult: String?

    init(_ value: [String: Any]) {
        installedTag = value["installed_tag"] as? String
        pendingTag = value["pending_tag"] as? String
        waiting = value["waiting"] as? String
        applying = value["applying"] as? Bool ?? false
        lastResult = value["last_result"] as? String
    }

    /// `zed-v1.29.3-zlink.7` → `1.29.3 zlink.7`.
    static func short(_ tag: String) -> String {
        let trimmed = tag.hasPrefix("zed-v") ? String(tag.dropFirst(5)) : tag
        return trimmed.replacingOccurrences(of: "-zlink.", with: " zlink.")
    }

    var waitingText: String {
        if applying { return "устанавливается, Zed перезапускается…" }
        switch waiting ?? "" {
        case "turns_running": return "ждёт, пока агенты закончат"
        case "waiting_approval": return "ждёт: тред ждёт подтверждения"
        case "waiting_input": return "ждёт: тред ждёт ответа"
        case "autopilot_job_due": return "ждёт: скоро задание автопилота"
        case "settling": return "все треды стоят, установка через пару минут"
        case "zed_hung": return "ждёт: Zed не отвечает"
        case "bridge_busy": return "ждёт ответа Zed"
        case "no_zed_control": return "управление Zed не настроено"
        default: return "установится, когда все треды остановятся"
        }
    }

    var lastResultText: String? {
        guard let lastResult else { return nil }
        let parts = lastResult.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "installed": return "Установлено обновление \(Self.short(parts[1]))."
        case "failed": return "Обновление \(Self.short(parts[1])) не запустилось, оставлена прежняя версия."
        case "postponed": return "Обновление \(Self.short(parts[1])) отложено: Zed не закрылся."
        default: return nil
        }
    }
}

enum ZedOperation: Equatable {
    case idle
    case starting
    case restarting
}

enum ZedHealth: Equatable {
    case unknown
    case running
    case hung
    case down
    case starting
    case restarting

    var label: String {
        switch self {
        case .unknown: "Неизвестно"
        case .running: "Работает"
        case .hung: "Не отвечает"
        case .down: "Не запущен"
        case .starting: "Запуск…"
        case .restarting: "Перезапуск…"
        }
    }
}

/// Zed-control state for one gateway + target. A different scope reads as a fresh state.
struct ZedControlState {
    var scope: String
    var status: ZedControlStatus?
    /// The gateway does not know `zed.*` (HTTP 403 `UNSUPPORTED_CAPABILITY`).
    var unsupported = false
    var operation = ZedOperation.idle
    var issue = ""
}

/// The restart confirmation. `generating` is set once the gateway answered `TURNS_RUNNING`.
struct ZedRestartPrompt: Identifiable, Equatable {
    let id = UUID()
    let generating: Int?

    var title: String { generating == nil ? "Перезапустить Zed?" : "Агенты ещё работают" }
    var message: String {
        guard let generating else {
            return "Zed закроется и запустится снова. Открытая сессия переподключится сама."
        }
        return ZedControlText.runningAgents(generating) + (generating == 1 ? " Перезапуск прервёт его." : " Перезапуск прервёт их.")
    }
    var confirmTitle: String { generating == nil ? "Перезапустить Zed" : "Всё равно перезапустить" }
    var force: Bool { generating != nil }
}

enum ZedControlText {
    static func runningAgents(_ count: Int) -> String {
        let lastDigit = count % 10
        let lastTwo = count % 100
        if lastDigit == 1 && lastTwo != 11 { return "Сейчас работает \(count) агент." }
        if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return "Сейчас работают \(count) агента." }
        return "Сейчас работают \(count) агентов."
    }

    static func failure(_ error: Error) -> String {
        if case GatewayFailure.native(let code) = error {
            switch code {
            case "BUSY": return "Zed уже запускается или перезапускается."
            case "START_FAILED": return "Не удалось запустить Zed."
            case "UNSUPPORTED_CAPABILITY": return "Управление Zed не настроено на этом gateway."
            case "NO_PENDING_UPDATE": return "Нет готового обновления Zed."
            default: break
            }
        }
        return error.localizedDescription
    }
}
