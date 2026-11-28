import Foundation

enum GatewayFailure: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case changedIdentity
    case redirected
    case status(Int)
    case native(String)
    /// `zed.restart` refused because Agent turns are running (`TURNS_RUNNING`, with `generating`).
    case turnsRunning(Int)

    var isTransientRouteFailure: Bool {
        guard case .native(let message) = self else { return false }
        return [
            "No network connection. Check the phone's network settings.",
            "Gateway name could not be resolved. Check the saved hostname and VPN DNS route.",
            "Gateway request timed out. Check the phone's private route and retry.",
            "Could not connect to the gateway. Check the private route and address.",
            "Gateway connection dropped. Check the phone's private route and retry."
        ].contains(message)
    }

    /// HTTPS identity (certificate) failure, as mapped in `GatewayClient.call`.
    static let tlsFailureMessage = "HTTPS identity could not be verified. Check the hostname and certificate."

    /// The address could not be reached at all (connect, timeout, TLS, no route), as opposed to an
    /// answer from a gateway. Only these switch between a profile's two configured addresses.
    static func isTransport(_ error: Error) -> Bool {
        if let failure = error as? GatewayFailure {
            if failure.isTransientRouteFailure { return true }
            if case .native(let message) = failure { return message == tlsFailureMessage }
            return false
        }
        if let error = error as? URLError { return error.code != .cancelled }
        return false
    }

    /// A gateway that predates a gateway-local method answers HTTP 403 `UNSUPPORTED_CAPABILITY`.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        switch failure {
        case .status(let status): return status == 403
        case .native(let code):
            return ["UNSUPPORTED_CAPABILITY", "UNKNOWN_METHOD", "METHOD_NOT_FOUND", "UNSUPPORTED_METHOD", "HTTP 403"].contains(code)
        default: return false
        }
    }

    /// The thread exists but Zed has not loaded it (for example after a restart); `thread.open` recovers it.
    var isThreadNotLoaded: Bool {
        guard case .native(let code) = self else { return false }
        return code == "THREAD_NOT_LOADED" || code == "THREAD_NOT_EXPOSED"
    }

    /// The project is known but not open in Zed and cannot be served from disk (a closed SSH
    /// project, wave 3 §6.3); `workspace.open` opens it.
    var isProjectNotOpen: Bool {
        guard case .native(let code) = self else { return false }
        return code == "PROJECT_NOT_OPEN"
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS address without credentials, query, or fragment."
        case .invalidResponse: "The gateway sent an unexpected response."
        case .changedIdentity: "Gateway identity changed. No device credential was sent."
        case .redirected: "The endpoint redirected. Check the saved address before reconnecting."
        case .status(let status): "Gateway returned HTTP \(status)."
        case .turnsRunning(let count): "Agent turns are running (\(count)). Restarting Zed would interrupt them."
        case .native(let code):
            switch code {
            case "UNAUTHENTICATED": "Device pairing is missing or revoked."
            case "THREAD_NOT_EXPOSED": "This thread is no longer exposed in desktop Zed."
            case "THREAD_NOT_LOADED": "Desktop Zed has not loaded this thread (THREAD_NOT_LOADED)."
            case "FILE_TOO_LARGE": "Files can be up to 25 MiB (FILE_TOO_LARGE)."
            case "INSTANCE_UNAVAILABLE": "Desktop Zed is unavailable."
            case "RESYNC_REQUIRED": "Event history changed; refreshing the native snapshot."
            case "HOST_UNAVAILABLE": "Zed could not connect to that host. Check desktop Zed for a password prompt or error."
            case "INVALID_COMMAND": "Zed could not read that SSH command. Use the form ssh user@host -p 2222."
            case "UNSUPPORTED_CAPABILITY": "This action is not enabled in desktop Zed."
            case "PROJECT_NOT_OPEN": "Проект не открыт в Zed (PROJECT_NOT_OPEN). Откройте его в Zed, чтобы работать с файлами."
            default: code
            }
        }
    }
}

/// Which configured address of each profile is in use, shared by every `GatewayClient` of the
/// process. Changes are posted on the main queue so `ProfileStore` can store
/// `lastWorkingEndpoint` and the UI can show the active route.
final class EndpointSelection: @unchecked Sendable {
    static let shared = EndpointSelection()
    /// `userInfo`: `profile_id` (UUID string), `endpoint` (String).
    static let didChange = Notification.Name("zedlink.endpointSelection.didChange")
    private let lock = NSLock()
    private var active: [UUID: String] = [:]

    func active(for profile: ConnectionProfile) -> String {
        lock.lock()
        let value: String? = active[profile.id]
        lock.unlock()
        if let value, profile.endpoints.contains(value) { return value }
        return profile.preferredEndpoint
    }

    func record(_ endpoint: String, for profile: ConnectionProfile) {
        lock.lock()
        let changed: Bool = active[profile.id] != endpoint
        active[profile.id] = endpoint
        lock.unlock()
        // Only real switches (and the first check of a launch) are posted: every RPC records.
        guard changed else { return }
        let info: [String: String] = ["profile_id": profile.id.uuidString, "endpoint": endpoint]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: EndpointSelection.didChange, object: nil, userInfo: info)
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct GatewayClient {
    private static let redirectDelegate = NoRedirect()
    private static let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    private static func identitySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // An explicit endpoint test must finish with a result even when a VPN route is absent.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }
    let profile: ConnectionProfile
    let token: String?
    var targetID: String? = nil

    /// The address requests go to now (see `EndpointSelection`).
    var activeEndpoint: String { EndpointSelection.shared.active(for: profile) }

    private static func base(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw GatewayFailure.invalidEndpoint
        }
        return url
    }

    private static func address(_ path: String, at endpoint: String) throws -> URL {
        let root = try base(endpoint).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let result = URL(string: root + path) else { throw GatewayFailure.invalidEndpoint }
        return result
    }

    private func call(_ path: String, at endpoint: String, payload: [String: Any]? = nil, authorized: Bool = false,
                      method: String? = nil, freshTransport: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: try Self.address(path, at: endpoint))
        request.timeoutInterval = freshTransport ? 20 : 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method ?? (payload == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let token else { throw GatewayFailure.native("UNAUTHENTICATED") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        // Identity checks are small, unauthenticated reads. A fresh URLSession avoids
        // reusing a connection created before an iPhone VPN route changed.
        let transport = freshTransport ? Self.identitySession() : Self.session
        defer { if freshTransport { transport.finishTasksAndInvalidate() } }
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet:
                throw GatewayFailure.native("No network connection. Check the phone's network settings.")
            case .cannotFindHost, .dnsLookupFailed:
                throw GatewayFailure.native("Gateway name could not be resolved. Check the saved hostname and VPN DNS route.")
            case .timedOut:
                throw GatewayFailure.native("Gateway request timed out. Check the phone's private route and retry.")
            case .cannotConnectToHost:
                throw GatewayFailure.native("Could not connect to the gateway. Check the private route and address.")
            case .networkConnectionLost:
                throw GatewayFailure.native("Gateway connection dropped. Check the phone's private route and retry.")
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                throw GatewayFailure.native(GatewayFailure.tlsFailureMessage)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayFailure.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw GatewayFailure.redirected }
        guard data.count <= 4_194_304,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayFailure.invalidResponse
        }
        guard http.statusCode == 200 else {
            // Gateway-level methods (zed.*) send `{"error":{"code":…}}`; older paths send a string.
            if let error = object["error"] as? [String: Any], let code = error["code"] as? String {
                if code == "TURNS_RUNNING" { throw GatewayFailure.turnsRunning(error["generating"] as? Int ?? 0) }
                throw GatewayFailure.native(code)
            }
            throw GatewayFailure.native(object["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return object
    }

    /// The `gateway_id` at one exact address (the connection editor's "Test" buttons).
    func gatewayID(at endpoint: String) async throws -> String {
        let object = try await call("/v1/gateway", at: endpoint, freshTransport: true)
        guard object["version"] as? Int == 1, let id = object["gateway_id"] as? String else {
            throw GatewayFailure.invalidResponse
        }
        return id
    }

    /// The `gateway_id` at the active address, trying the other configured address only when the
    /// first one cannot be reached at all.
    func gatewayID() async throws -> String {
        let first: String = activeEndpoint
        do {
            return try await gatewayID(at: first)
        } catch let error where GatewayFailure.isTransport(error) {
            guard let other = profile.endpoints.first(where: { $0 != first }) else { throw error }
            do { return try await gatewayID(at: other) } catch let second where GatewayFailure.isTransport(second) { throw error }
        }
    }

    /// Checks HTTPS and `gateway_id == profile.gatewayID` at the active address. On a transport
    /// failure (never on an HTTP answer or a different gateway) the other configured address is
    /// checked the same way. The address that passed becomes the active one and is returned.
    /// Both are addresses the user saved for this gateway; there is no other fallback.
    @discardableResult
    func verifyIdentity() async throws -> String {
        let first: String = activeEndpoint
        do {
            try await verifyIdentity(at: first)
            EndpointSelection.shared.record(first, for: profile)
            return first
        } catch let error where GatewayFailure.isTransport(error) {
            guard let other = profile.endpoints.first(where: { $0 != first }) else { throw error }
            do {
                try await verifyIdentity(at: other)
            } catch let second where GatewayFailure.isTransport(second) {
                throw error
            }
            EndpointSelection.shared.record(other, for: profile)
            return other
        }
    }

    private func verifyIdentity(at endpoint: String) async throws {
        guard try await gatewayID(at: endpoint) == profile.gatewayID else { throw GatewayFailure.changedIdentity }
    }

    func pair(code: String, deviceName: String) async throws -> (deviceID: String, token: String) {
        let endpoint: String = try await verifyIdentity()
        let object = try await call("/v1/pair", at: endpoint, payload: ["code": code, "device_name": deviceName])
        guard object["gateway_id"] as? String == profile.gatewayID,
              let deviceID = object["device_id"] as? String,
              let token = object["token"] as? String, token.count == 64 else {
            throw GatewayFailure.invalidResponse
        }
        return (deviceID, token)
    }

    func rpc(_ method: String, params: [String: Any] = [:], requestID: String = UUID().uuidString) async throws -> [String: Any] {
        // Recheck before every authenticated call. A changed endpoint never receives the token.
        // The request itself is never retried on the other address: delivery stays unknown.
        let endpoint: String = try await verifyIdentity()
        var envelope: [String: Any] = ["version": 1, "request_id": requestID, "method": method, "params": params]
        if method != "instance.list", let targetID { envelope["target_id"] = targetID }
        let object = try await call("/v1/rpc", at: endpoint, payload: envelope, authorized: true)
        guard object["version"] as? Int == 1, object["request_id"] as? String == requestID else {
            throw GatewayFailure.invalidResponse
        }
        if let error = object["error"] as? [String: Any], let code = error["code"] as? String {
            if code == "TURNS_RUNNING" { throw GatewayFailure.turnsRunning(error["generating"] as? Int ?? 0) }
            throw GatewayFailure.native(code)
        }
        guard let result = object["result"] as? [String: Any] else { throw GatewayFailure.invalidResponse }
        return result
    }

    func apnsStatus() async throws -> (supported: Bool, enabled: Bool) {
        let endpoint: String = try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", at: endpoint, authorized: true)
        guard let supported = result["supported"] as? Bool,
              let enabled = result["enabled"] as? Bool else { throw GatewayFailure.invalidResponse }
        return (supported, enabled)
    }

    func registerAPNs(token: String, environment: String) async throws {
        let endpoint: String = try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", at: endpoint, payload: ["token": token, "environment": environment], authorized: true)
        guard result["enabled"] as? Bool == true else { throw GatewayFailure.invalidResponse }
    }

    func unregisterAPNs() async throws {
        let endpoint: String = try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", at: endpoint, authorized: true, method: "DELETE")
        guard result["enabled"] as? Bool == false else { throw GatewayFailure.invalidResponse }
    }

    func testAPNs() async throws {
        let endpoint: String = try await verifyIdentity()
        let result = try await call("/v1/notifications/apns/test", at: endpoint, payload: [:], authorized: true)
        guard result["delivered"] as? Bool == true else { throw GatewayFailure.invalidResponse }
    }

    func eventStream(threadID: String, afterSequence: Int) throws -> AsyncThrowingStream<[String: Any], Error> {
        guard let token else { throw GatewayFailure.native("Pair this device first.") }
        // The address the last identity check passed on (every caller made an RPC before).
        guard var components = URLComponents(string: activeEndpoint), components.scheme == "https" else {
            throw GatewayFailure.native("ZedLink requires trusted HTTPS.")
        }
        components.scheme = "wss"
        components.path = "/v1/events"
        components.queryItems = [
            URLQueryItem(name: "thread_id", value: threadID),
            URLQueryItem(name: "after_sequence", value: String(afterSequence)),
        ] + (targetID.map { [URLQueryItem(name: "target_id", value: $0)] } ?? [])
        guard let url = components.url else { throw GatewayFailure.invalidResponse }
        let task = Self.session.webSocketTask(with: url, protocols: ["zedlink-v1", "zedlink-token-\(token)"])
        task.maximumMessageSize = 4_194_304
        return AsyncThrowingStream { continuation in
            task.resume()
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    if Task.isCancelled { return }
                    let timeout = Task {
                        // A native Zed probe may take up to six seconds. Allow for
                        // transport scheduling without treating a slow turn as a
                        // dead gateway connection.
                        try? await Task.sleep(for: .seconds(12))
                        if Task.isCancelled { return }
                        continuation.finish(throwing: GatewayFailure.native("Gateway event stream timed out."))
                        task.cancel(with: .goingAway, reason: nil)
                    }
                    task.sendPing { error in
                        timeout.cancel()
                        if let error {
                            continuation.finish(throwing: error)
                            task.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            }
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GatewayFailure.invalidResponse }
                        if let error = envelope["error"] as? [String: Any], let code = error["code"] as? String { throw GatewayFailure.native(code) }
                        guard let result = envelope["result"] as? [String: Any] else { throw GatewayFailure.invalidResponse }
                        continuation.yield(result)
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                receiver.cancel(); heartbeat.cancel(); task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
