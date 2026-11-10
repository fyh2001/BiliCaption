import Foundation
import Network
import CoreFoundation

struct PlaybackControl {
    let id: String
    let action: String
    let sourceId: String
    let arguments: [String: Any]
    let createdAt: Double
}

final class BridgeServer {
    private let queue = DispatchQueue(label: "local.bilicaptions.http")
    private var listener: NWListener?
    var onMessage: ((BridgeMessage) -> Bool)?
    var needsTrack: ((BridgeMessage) -> Bool)?
    var onHealth: (() -> String)?
    var onFailure: ((String) -> Void)?
    var onControlResult: ((String, Bool, String?) -> Void)?
    var onPreferences: (() -> [String: Any])?
    private let maxBody = 8 * 1024 * 1024
    private var controls: [PlaybackControl] = []
    private let port: UInt16
    private let bridgeToken: String

    init(port: UInt16 = 17373, token: String? = nil) {
        self.port = port
        self.bridgeToken = token ?? (Bundle.main.object(forInfoDictionaryKey: "BiliCaptionBridgeToken") as? String) ?? ""
    }

    @discardableResult
    func enqueuePlaybackToggle(sourceId: String) -> Bool {
        enqueue(action: "togglePlayback", sourceId: sourceId) != nil
    }

    @discardableResult
    func enqueuePlaybackRate(sourceId: String, rate: Double) -> Bool {
        enqueue(action: "setPlaybackRate", sourceId: sourceId, arguments: ["rate": rate]) != nil
    }

    /// Only a small set of typed playback/account operations can cross the local bridge.
    @discardableResult
    func enqueue(action: String, sourceId: String, arguments: [String: Any] = [:]) -> String? {
        guard sourceId.range(of: #"^\d{1,20}$"#, options: .regularExpression) != nil,
              let arguments = Self.validatedArguments(action: action, arguments: arguments) else { return nil }
        let control = PlaybackControl(id: UUID().uuidString.lowercased(), action: action,
                                      sourceId: sourceId, arguments: arguments,
                                      createdAt: ProcessInfo.processInfo.systemUptime)
        queue.async { [weak self] in
            guard let self else { return }
            self.expireControls()
            guard self.controls.count < 100 else {
                DispatchQueue.main.async { self.onControlResult?(control.id, false, "操作过多，请稍后重试") }
                return
            }
            self.controls.append(control)
            self.queue.asyncAfter(deadline: .now() + Self.controlTimeout(for: action)) { [weak self] in
                self?.finishControl(id: control.id, ok: false, error: Self.timeoutMessage(for: action))
            }
        }
        return control.id
    }

    static func controlTimeout(for action: String) -> Double {
        switch action {
        case "loadAccount": return 60
        case "saveFavorites", "addWatchLater": return 120
        default: return 15
        }
    }

    private static func timeoutMessage(for action: String) -> String {
        switch action {
        case "saveFavorites", "addWatchLater":
            return "120 秒内未收到 B 站确认，浏览器可能仍在执行。请刷新账号列表确认结果后再重试。"
        case "loadAccount":
            return "60 秒内未收到账号列表，请检查 B 站登录状态或稍后刷新。"
        default:
            return "浏览器未在 15 秒内确认操作，请检查视频标签页。"
        }
    }

    static func validatedArguments(action: String, arguments: [String: Any]) -> [String: Any]? {
        let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
        func number(_ key: String, upperBound: Double = 31_536_000) -> Double? {
            guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let double = value.doubleValue
            return double.isFinite && double >= 0 && double <= upperBound ? double : nil
        }
        func text(_ key: String, maximum: Int = 256) -> String? {
            guard let value = arguments[key] as? String, !value.isEmpty, value.utf8.count <= maximum,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        func keys(_ allowed: [String]) -> Bool { Set(arguments.keys).isSubset(of: Set(allowed)) }
        switch action {
        case "togglePlayback", "previousItem", "nextItem", "enableSubtitles", "resyncSubtitles":
            return arguments.isEmpty ? [:] : nil
        case "setPlaybackRate":
            guard keys(["rate"]), let rate = number("rate", upperBound: 3), rates.contains(rate) else { return nil }
            return ["rate": rate]
        case "seek":
            guard keys(["time"]), let time = number("time") else { return nil }
            return ["time": time]
        case "playItem":
            guard keys(["url", "time", "rate"]), let rawURL = arguments["url"] as? String,
                  let url = canonicalVideoURL(rawURL) else { return nil }
            var valid: [String: Any] = ["url": url]
            if arguments["time"] != nil {
                guard let time = number("time") else { return nil }
                valid["time"] = time
            }
            if arguments["rate"] != nil {
                guard let rate = number("rate", upperBound: 3), rates.contains(rate) else { return nil }
                valid["rate"] = rate
            }
            return valid
        case "selectSubtitle":
            guard keys(["subtitleID"]), let id = text("subtitleID") else { return nil }
            return ["subtitleID": id]
        case "loadAccount":
            guard keys(["folderID"]) else { return nil }
            if arguments["folderID"] == nil { return [:] }
            guard let id = text("folderID", maximum: 128) else { return nil }
            return ["folderID": id]
        case "saveFavorites", "addWatchLater":
            guard keys(action == "saveFavorites" ? ["folderID", "urls"] : ["urls"]),
                  let rawURLs = arguments["urls"] as? [String], !rawURLs.isEmpty, rawURLs.count <= 100 else { return nil }
            let urls = rawURLs.compactMap(canonicalVideoURL)
            guard urls.count == rawURLs.count else { return nil }
            var valid: [String: Any] = ["urls": Array(NSOrderedSet(array: urls))]
            if action == "saveFavorites" {
                guard let id = text("folderID", maximum: 128), id.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else { return nil }
                valid["folderID"] = id
            }
            return valid
        default: return nil
        }
    }

    private func expireControls() {
        let now = ProcessInfo.processInfo.systemUptime
        let expired = controls.filter { now - $0.createdAt >= Self.controlTimeout(for: $0.action) }
        for control in expired { finishControl(id: control.id, ok: false, error: Self.timeoutMessage(for: control.action)) }
    }

    @discardableResult
    private func finishControl(id: String, ok: Bool, error: String?) -> Bool {
        guard let index = controls.firstIndex(where: { $0.id == id.lowercased() }) else { return false }
        let control = controls.remove(at: index)
        DispatchQueue.main.async { [weak self] in self?.onControlResult?(control.id, ok, error) }
        return true
    }

    private func controlReply(for message: BridgeMessage) -> [String: Any]? {
        guard message.kind == "playback", let sourceId = message.sourceId else { return nil }
        expireControls()
        // Pause/seek/subtitle controls should remain responsive while an account
        // request is in flight. Navigation retains FIFO order with account work:
        // moving the page early could destroy the context executing a write.
        let immediateActions: Set<String> = ["togglePlayback", "setPlaybackRate", "seek", "selectSubtitle", "enableSubtitles", "resyncSubtitles"]
        let pending = controls.filter { $0.sourceId == sourceId }
        guard let control = pending.first(where: { immediateActions.contains($0.action) }) ?? pending.first else { return nil }
        var value: [String: Any] = ["id": control.id, "action": control.action, "sourceId": control.sourceId]
        for (key, argument) in control.arguments { value[key] = argument }
        return value
    }

    private func acknowledge(_ target: String) -> Bool {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == "/control/ack",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              UUID(uuidString: id) != nil else { return false }
        return finishControl(id: id, ok: true, error: nil)
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async { self?.onFailure?("本机连接失败：\(error.localizedDescription)") }
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.receive($0) }
            listener.start(queue: queue)
        } catch { onFailure?(error.localizedDescription) }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        var finished = false
        let timeout = DispatchWorkItem { if !finished { finished = true; connection.cancel() } }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)

        func respond(_ status: Int, _ body: String) {
            guard !finished else { return }
            finished = true
            timeout.cancel()
            let names = [200:"OK",400:"Bad Request",401:"Unauthorized",404:"Not Found",405:"Method Not Allowed",413:"Payload Too Large"]
            let data = Data(body.utf8)
            var response = Data("HTTP/1.1 \(status) \(names[status] ?? "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            response.append(data)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }

        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !finished else { return }
                if let data { buffer.append(data) }
                if buffer.count > self.maxBody + 16_384 { respond(413, "{\"ok\":false}"); return }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 16_384 { respond(413, "{\"ok\":false}") }
                    else if complete || error != nil { respond(400, "{\"ok\":false}") }
                    else { read() }
                    return
                }
                guard end.upperBound <= 16_384, let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { respond(400, "{\"ok\":false}"); return }
                let lines = header.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ")
                guard request.count == 3 else { respond(400, "{\"ok\":false}"); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { respond(400, "{\"ok\":false}"); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { respond(400, "{\"ok\":false}"); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["x-bili-token"] == bridgeToken else { respond(401, "{\"ok\":false}"); return }
                if request[0] == "GET", request[1] == "/health" {
                    DispatchQueue.main.async {
                        let reply = self.onHealth?() ?? "{\"ok\":true,\"app\":\"BiliCaption\",\"version\":\"1.0.0\"}"
                        self.queue.async { respond(200, reply) }
                    }
                    return
                }
                if request[0] == "GET", request[1].hasPrefix("/control/ack") {
                    let acknowledged = self.acknowledge(String(request[1]))
                    respond(acknowledged ? 200 : 404, acknowledged ? "{\"ok\":true}" : "{\"ok\":false}")
                    return
                }
                guard request[0] == "POST" else { respond(405, "{\"ok\":false}"); return }
                guard request[1] == "/update" || request[1] == "/control/result" else { respond(404, "{\"ok\":false}"); return }
                guard headers["transfer-encoding"] == nil,
                      let lengthString = headers["content-length"], let length = Int(lengthString), length >= 0 else { respond(400, "{\"ok\":false}"); return }
                guard length <= self.maxBody else { respond(413, "{\"ok\":false}"); return }
                let available = buffer.count - end.upperBound
                guard available >= length else {
                    if complete || error != nil { respond(400, "{\"ok\":false}") } else { read() }
                    return
                }
                guard available == length else { respond(400, "{\"ok\":false}"); return }
                let body = Data(buffer[end.upperBound...])
                if request[1] == "/control/result" {
                    guard let result = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          Set(result.keys).isSubset(of: ["id", "ok", "error"]),
                          let id = result["id"] as? String, UUID(uuidString: id) != nil,
                          let flag = result["ok"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                          result["error"] == nil || (result["error"] as? String)?.count ?? 1001 <= 1000 else {
                        respond(400, "{\"ok\":false}"); return
                    }
                    let acknowledged = self.finishControl(id: id, ok: flag.boolValue, error: result["error"] as? String)
                    respond(acknowledged ? 200 : 404, acknowledged ? "{\"ok\":true}" : "{\"ok\":false}")
                    return
                }
                guard let message = try? JSONDecoder().decode(BridgeMessage.self, from: body) else { respond(400, "{\"ok\":false}"); return }
                DispatchQueue.main.async {
                    let accepted = self.onMessage?(message) ?? false
                    let needsTrack = accepted && (self.needsTrack?(message) ?? false)
                    let preferences = accepted ? self.onPreferences?() : nil
                    self.queue.async {
                        var reply: [String: Any] = ["ok": accepted]
                        if accepted {
                            reply["needsTrack"] = needsTrack
                            if let control = self.controlReply(for: message) { reply["control"] = control }
                            if let preferences, JSONSerialization.isValidJSONObject(preferences) { reply["preferences"] = preferences }
                        }
                        let data = try? JSONSerialization.data(withJSONObject: reply)
                        respond(accepted ? 200 : 400, data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}")
                    }
                }
            }
        }
        read()
    }
}
