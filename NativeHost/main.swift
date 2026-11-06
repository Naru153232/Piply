import Foundation
import AppKit

let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support", isDirectory: true)
let directory = applicationSupport.appendingPathComponent("Piply", isDirectory: true)
let legacyDirectory = applicationSupport.appendingPathComponent("UniversalPiP", isDirectory: true)
if !FileManager.default.fileExists(atPath: directory.path),
   FileManager.default.fileExists(atPath: legacyDirectory.path) {
    try? FileManager.default.moveItem(at: legacyDirectory, to: directory)
}
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readExactly(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try? input.read(upToCount: count - result.count),
              !chunk.isEmpty else { return nil }
        result.append(chunk)
    }
    return result
}

func readMessage() -> [String: Any]? {
    guard let lengthData = readExactly(4) else { return nil }
    let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    guard let data = readExactly(Int(length)) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func writeMessage(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(data.count).littleEndian
    output.write(Data(bytes: &length, count: 4))
    output.write(data)
}

func writeJSON(_ object: [String: Any], to name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}

func launchPiPIfNeeded() throws {
    let identifier = "com.naru.piply"
    if NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .contains(where: { !$0.isTerminated }) { return }
    // Launch the app containing this registered helper, not another build
    // Launch Services might find under the same bundle identifier.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == identifier else {
        throw NSError(domain: "com.naru.piply", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "アプリが見つかりません。PiplyでChrome連携を設定し直してください。"
        ])
    }
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-g", app.path, "--args", "--chrome-pip"]
    // stdout is exclusively the Native Messaging protocol.
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.standardError
    try launcher.run()
    launcher.waitUntilExit()
    if launcher.terminationStatus != 0 {
        throw NSError(domain: "com.naru.piply", code: 2, userInfo: [NSLocalizedDescriptionKey: "Piplyを起動できませんでした。"])
    }
}

while let message = readMessage() {
    do {
        let action = message["action"] as? String ?? ""
        switch action {
        case "syncTabs":
            try writeJSON([
                "connectedAt": Date().timeIntervalSince1970,
                "extensionVersion": message["extensionVersion"] as? String ?? "",
                "tabs": message["tabs"] as? [[String: Any]] ?? []
            ], to: "chrome-state.json")
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.naru.piply.ChromeState"), object: nil, userInfo: nil, deliverImmediately: true
            )
        case "streamOffer", "captureTabError", "captureTabNeedsPermission", "videoWaiting", "selectPiPTab", "tabCaptureStopped", "sourceTabClosed":
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("commands"), withIntermediateDirectories: true)
            let name = String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
            try writeJSON(message, to: "commands/" + name)
            // Persist the offer before launch so a cold-started app can read it
            // even if its notification observer is not installed yet.
            if action == "streamOffer" { try launchPiPIfNeeded() }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.naru.piply.ChromeCommand"), object: nil, userInfo: nil, deliverImmediately: true
            )
        default:
            break
        }

        // Only control/signaling metadata passes through this queue; never video.
        let queue = directory.appendingPathComponent("requests", isDirectory: true)
        let queued = (try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let requestURL = queued?.first ?? directory.appendingPathComponent("chrome-request.json")
        var response: [String: Any] = ["ok": true]
        if let data = try? Data(contentsOf: requestURL),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            response["command"] = command
            try? FileManager.default.removeItem(at: requestURL)
        }
        writeMessage(response)
    } catch {
        writeMessage(["ok": false, "error": error.localizedDescription,
                      "requestId": message["requestId"] ?? ""])
    }
}
