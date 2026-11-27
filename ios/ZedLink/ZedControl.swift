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

    init?(_ result: [String: Any]) {
        guard let bridge = result["bridge"] as? String else { return nil }
        self.bridge = bridge
        control = result["control"] as? Bool ?? false
        instanceID = Self.text(result["instance_id"])
        epoch = Self.text(result["epoch"])
        generating = result["generating"] as? Int ?? 0
        restarting = result["restarting"] as? Bool ?? false
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
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
            default: break
            }
        }
        return error.localizedDescription
    }
}
