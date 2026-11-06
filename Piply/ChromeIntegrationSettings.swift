import Foundation

enum ChromeIntegrationError: LocalizedError {
    case invalidExtensionID
    case nativeHostMissing

    var errorDescription: String? {
        switch self {
        case .invalidExtensionID:
            return L10n.text("Chrome 拡張機能 ID は 32 文字の英小文字で入力してください。", "Enter the Chrome extension ID as 32 lowercase letters.")
        case .nativeHostMissing:
            return L10n.text("Native Host がアプリ内に見つかりません。build.sh でアプリを作り直してください。", "The Native Host was not found in the app. Rebuild the app with build.sh.")
        }
    }
}

enum ChromeIntegrationSettings {
    static let extensionIDKey = "chromeExtensionID"
    static let hostName = "com.naru.piply"
    private static let legacyHostName = "com.example.universal_pip"

    static var extensionID: String {
        get { UserDefaults.standard.string(forKey: extensionIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: extensionIDKey) }
    }

    static var manifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostName).json")
    }

    private static var legacyManifestURL: URL {
        manifestURL.deletingLastPathComponent().appendingPathComponent("\(legacyHostName).json")
    }

    static var isInstalled: Bool {
        guard let hostURL = Bundle.main.url(forAuxiliaryExecutable: "PiplyNativeHost"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registeredPath = manifest["path"] as? String else { return false }
        return URL(fileURLWithPath: registeredPath).standardizedFileURL == hostURL.standardizedFileURL
            && FileManager.default.isExecutableFile(atPath: hostURL.path)
    }

    @discardableResult
    static func repairRegistrationIfPossible() throws -> Bool {
        let savedID = extensionID
        guard !savedID.isEmpty else { return false }
        if !isInstalled { try install(extensionID: savedID) }
        return isInstalled
    }

    static func install(extensionID rawID: String) throws {
        let extensionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = extensionID.count == 32 && extensionID.allSatisfy { ("a"..."p").contains(String($0)) }
        guard valid else { throw ChromeIntegrationError.invalidExtensionID }

        guard let hostURL = Bundle.main.url(forAuxiliaryExecutable: "PiplyNativeHost"),
              FileManager.default.isExecutableFile(atPath: hostURL.path) else {
            throw ChromeIntegrationError.nativeHostMissing
        }

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Piply native bridge",
            "path": hostURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let directory = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
        try? FileManager.default.removeItem(at: legacyManifestURL)
        self.extensionID = extensionID
    }
}
