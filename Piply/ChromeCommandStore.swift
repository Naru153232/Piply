import Foundation

struct ChromeCommand: Codable {
    let action: String
    let tabId: Int?
    let windowId: Int?
    let title: String
    let url: String?
    let viewportWidth: Double?
    let viewportHeight: Double?
    let outerWidth: Double?
    let outerHeight: Double?
    let error: String?
    let requestId: String?
    let sdp: String?
    let addAsTab: Bool?
    let streamId: String?
    let videoElement: Bool?
}

struct ChromeTab: Codable, Identifiable, Equatable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String?
    let active: Bool

    var usesProtectedVideo: Bool {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return host.contains("netflix.com") || host.contains("primevideo.com") ||
            (host.contains("amazon.") && url?.contains("/video") == true)
    }
}

struct ChromeState: Codable {
    let connectedAt: TimeInterval
    let extensionVersion: String?
    let tabs: [ChromeTab]
}

enum ChromeCommandStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UniversalPiP", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("chrome-command.json") }
    static var stateFile: URL { directory.appendingPathComponent("chrome-state.json") }
    static var requestFile: URL { directory.appendingPathComponent("chrome-request.json") }
    static var requestQueue: URL { directory.appendingPathComponent("requests", isDirectory: true) }

    private static func enqueue(_ command: [String: Any]) throws {
        try FileManager.default.createDirectory(at: requestQueue, withIntermediateDirectories: true)
        let name = String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
        try JSONSerialization.data(withJSONObject: command).write(to: requestQueue.appendingPathComponent(name), options: .atomic)
    }

    static func requestStreamAnswer(tabID: Int, requestID: String, sdp: String, streamID: String? = nil) throws {
        var message: [String: Any] = ["action": "streamAnswer", "tabId": tabID, "requestId": requestID, "sdp": sdp]
        if let streamID { message["streamId"] = streamID }
        try enqueue(message)
    }

    static func loadAndConsume() -> ChromeCommand? {
        let queue = directory.appendingPathComponent("commands", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files + [file] {
            guard let data = try? Data(contentsOf: url) else { continue }
            try? FileManager.default.removeItem(at: url)
            if let command = try? JSONDecoder().decode(ChromeCommand.self, from: data) { return command }
        }
        return nil
    }

    static func loadState() -> ChromeState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(ChromeState.self, from: data)
    }

    static func requestCapture(tabID: Int, requestID: String, addAsTab: Bool = false) throws {
        try enqueue([
            "action": "captureTab", "tabId": tabID, "requestId": requestID,
            "allowFocusForPermission": true, "addAsTab": addAsTab
        ])
    }

    static func requestVideoReconnect(tabID: Int, requestID: String, streamID: String?) {
        var message: [String: Any] = ["action": "restartVideo", "tabId": tabID, "requestId": requestID]
        if let streamID { message["streamId"] = streamID }
        try? enqueue(message)
    }

    static func requestStopTabCapture(tabID: Int, requestID: String) {
        try? enqueue(["action": "stopTabCapture", "tabId": tabID, "requestId": requestID])
    }
}

