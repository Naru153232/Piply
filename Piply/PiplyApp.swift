import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep the closed window available for Dock/reopen requests without
    // creating another scene or interrupting the Chrome bridge.
    static var mainWindow: NSWindow?
    private var duplicateInstance: NSRunningApplication?
    private var focusedWindowHotKey: GlobalHotKey?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func requestExistingWindowRefresh() {
        DistributedNotificationCenter.default().postNotificationName(
            .universalPiPActivateExisting,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func olderRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentLaunchDate = NSRunningApplication.current.launchDate ?? Date()
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
            .filter { ($0.launchDate ?? .distantPast) <= currentLaunchDate }
            .min {
                let lhs = $0.launchDate ?? .distantPast
                let rhs = $1.launchDate ?? .distantPast
                return lhs == rhs ? $0.processIdentifier < $1.processIdentifier : lhs < rhs
            }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let existing = olderRunningInstance() else { return }
        duplicateInstance = existing
        requestExistingWindowRefresh()
        existing.activate(options: [])
        // Terminate before SwiftUI gets a chance to create this process's
        // scene. Deferring this by one run-loop produced a second window.
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep a second guard for two launches that started almost
        // simultaneously and were not both visible during will-finish.
        if let existing = duplicateInstance ?? olderRunningInstance() {
            requestExistingWindowRefresh()
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        focusedWindowHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)) {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            NotificationCenter.default.post(
                name: .universalPiPCaptureFocusedApplication,
                object: nil,
                userInfo: pid.map { ["processID": $0] }
            )
        }

        // Clear any duplicate scene restored from an older WindowGroup build.
        DispatchQueue.main.async { [weak self] in self?.keepOnlyOneMainWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        keepOnlyOneMainWindow()
    }

    private func keepOnlyOneMainWindow() {
        let mainWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.title == "Piply" }
        guard mainWindows.count > 1 else { return }
        let windowToKeep = mainWindows.first(where: { $0.isKeyWindow })
            ?? mainWindows.first(where: { $0.isVisible })
            ?? mainWindows[0]
        for window in mainWindows where window !== windowToKeep {
            window.close()
        }
        windowToKeep.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestExistingWindowRefresh()
        NSApp.activate(ignoringOtherApps: true)
        Self.mainWindow?.makeKeyAndOrderFront(nil)
        // The existing main window has already been shown. Returning false
        // prevents SwiftUI/AppKit from creating another one for the reopen.
        return false
    }
}

private final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { owner.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50504C59), id: 1) // PPLY
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@main
struct PiplyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SourcePickerModel()

    var body: some Scene {
        Window("Piply", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 500)
                .background(MainWindowReference())
        }
        .windowResizability(.contentSize)

        Settings {
            AppSettingsView(model: model)
        }

        MenuBarExtra("Piply", systemImage: "pip") {
            PiPMenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PiPMenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PiPTheme.defaultsKey) private var selectedTheme = PiPTheme.black.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.japanese.rawValue
    @ObservedObject var model: SourcePickerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Piply").font(.headline)
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("設定を開く", "Open Settings"))
            }
            .padding(12)

            Divider()

            Button {
                model.openLastFocusedApplication()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "macwindow.on.rectangle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("フォーカス中のアプリをPiP", "Show Focused App in PiP"))
                            .font(.subheadline.weight(.semibold))
                        if let name = model.lastFocusedApplicationName {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("⇧⌘P").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(10)
            }
            .buttonStyle(.plain)
            .disabled(model.lastFocusedApplicationName == nil)

            Divider()

            if model.permissionDenied {
                HStack(spacing: 10) {
                    Text(L10n.text("画面収録の許可が必要です", "Screen Recording Permission Required"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(L10n.text("システム設定を開く", "Open System Settings")) { model.openScreenRecordingSettings() }
                }
                .padding(10)
                Divider()
            }

            HStack {
                Button(L10n.text("Piplyを開く", "Open Piply")) {
                    NSApp.activate(ignoringOtherApps: true)
                    AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button(L10n.text("終了", "Quit")) { NSApp.terminate(nil) }
            }
            .padding(10)
        }
        .frame(width: 340)
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.japanese.locale)
        .modifier(PiplyAppTheme(theme: PiPTheme(rawValue: selectedTheme) ?? .black))
    }
}

private struct MainWindowReference: NSViewRepresentable {
    final class WindowReferenceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isReleasedWhenClosed = false
            AppDelegate.mainWindow = window
        }
    }

    func makeNSView(context: Context) -> WindowReferenceView { WindowReferenceView() }
    func updateNSView(_ nsView: WindowReferenceView, context: Context) {}
}

private struct AppSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PiPTheme.defaultsKey) private var selectedTheme = PiPTheme.black.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.japanese.rawValue
    @ObservedObject var model: SourcePickerModel
    @State private var status = SMAppService.mainApp.status
    @State private var isUpdating = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: L10n.text("一般", "General"), systemImage: "slider.horizontal.3") {
                    SettingsRow(title: L10n.text("言語", "Language")) {
                        AppLanguagePicker()
                    }
                    Divider()
                    SettingsRow(title: L10n.text("テーマ", "Theme")) {
                        PiPThemePicker()
                    }
                    Divider()
                    SettingsRow(title: L10n.text("タブバー", "Tab Bar")) {
                        PiPTabModePicker()
                    }
                }

                SettingsCard(title: L10n.text("Chrome タブ連携", "Chrome Tab Integration"), systemImage: "puzzlepiece.extension") {
                Text(L10n.text("拡張機能のページに表示される32文字のIDを入力すると、Chromeタブを直接PiP表示できます。", "Enter the 32-character ID shown on the extension page to display Chrome tabs directly in PiP."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(L10n.text("Chrome 拡張機能 ID", "Chrome Extension ID"), text: $model.chromeExtensionID)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.text("連携を設定", "Set Up Integration")) { model.installChromeIntegration() }
                        .buttonStyle(.borderedProminent)
                }
                HStack {
                    Label(chromeConnectionLabel,
                          systemImage: model.chromeConnected ? "checkmark.circle.fill" : (model.chromeIntegrationInstalled ? "clock" : "circle"))
                        .foregroundStyle(model.chromeConnected ? .green : .secondary)
                    Spacer()
                    Button(L10n.text("導入方法を開く", "Open Setup Instructions")) { model.openChromeExtensions() }
                }
                ChromeBlackScreenHelp()
                }

                SettingsCard(title: L10n.text("起動", "Startup"), systemImage: "power") {
                Toggle(L10n.text("Macへのログイン時に自動起動", "Launch at Login"), isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { updateLoginItem(enabled: $0) }
                ))
                .disabled(isUpdating)

                Text(L10n.text("ウィンドウを閉じてもバックグラウンドで動作します。完全に終了するには、アプリメニューの「Piplyを終了」（⌘Q）を選んでください。", "Piply continues running after you close its window. To quit completely, choose Quit Piply (⌘Q) from the app menu."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if status == .requiresApproval {
                    Text(L10n.text("自動起動を有効にするには、システム設定で許可してください。", "Allow Piply in System Settings to enable launch at login."))
                        .font(.callout)
                    Button(L10n.text("ログイン項目の設定を開く", "Open Login Items Settings")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
                }

                SettingsCard(title: L10n.text("アプリ情報", "About"), systemImage: "info.circle") {
                    SettingsRow(title: L10n.text("バージョン", "Version")) {
                        Text(appVersionDescription)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .frame(width: 520)
        .frame(minHeight: 560)
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.japanese.locale)
        .modifier(PiplyAppTheme(theme: PiPTheme(rawValue: selectedTheme) ?? .black))
        .background(SettingsInitialFocusClearer())
        .onAppear { status = SMAppService.mainApp.status }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = SMAppService.mainApp.status }
        }
    }

    private var chromeConnectionLabel: String {
        if model.chromeExtensionNeedsReload { return L10n.text("拡張機能の再読み込みが必要", "Extension Reload Required") }
        if model.chromeConnected { return L10n.text("Chrome 拡張機能と接続済み", "Connected to Chrome Extension") }
        if model.chromeIntegrationInstalled { return L10n.text("ID設定済み・接続待ち", "ID Saved — Waiting for Connection") }
        return L10n.text("未設定", "Not Configured")
    }

    private var appVersionDescription: String {
        AppVersion.current
    }

    private func updateLoginItem(enabled: Bool) {
        isUpdating = true
        errorMessage = nil
        Task { @MainActor in
            defer {
                status = SMAppService.mainApp.status
                isUpdating = false
            }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = L10n.text("自動起動の設定を変更できませんでした：\(error.localizedDescription)", "Could not change the launch-at-login setting: \(error.localizedDescription)")
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.body)
            Spacer(minLength: 20)
            content
        }
        .frame(minHeight: 28)
    }
}

private struct SettingsInitialFocusClearer: NSViewRepresentable {
    final class FocusClearingView: NSView {
        private var hasClearedInitialFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasClearedInitialFocus else { return }
            hasClearedInitialFocus = true

            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    func makeNSView(context: Context) -> FocusClearingView { FocusClearingView() }
    func updateNSView(_ nsView: FocusClearingView, context: Context) {}
}



enum PiPTabDisplayMode: String, CaseIterable {
    static let defaultsKey = "pipTabDisplayMode"
    case always
    case hover

    var title: String {
        switch self {
        case .always: return L10n.text("上部に常時表示", "Always Show Above Video")
        case .hover: return L10n.text("ホバー時に映像へ重ねる", "Overlay on Video When Hovering")
        }
    }

    static var saved: PiPTabDisplayMode {
        PiPTabDisplayMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .always
    }
}

struct PiPTabModePicker: View {
    @AppStorage(PiPTabDisplayMode.defaultsKey) private var mode = PiPTabDisplayMode.always.rawValue

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(PiPTabDisplayMode.allCases, id: \.rawValue) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 210, alignment: .trailing)
        .help(L10n.text("常時表示は映像の外側、ホバー表示は映像の上にタブバーを表示します。", "Always Show places the tab bar outside the video; Hover overlays it on the video."))
    }
}


enum PiPTheme: String, CaseIterable {
    static let defaultsKey = "pipTheme"
    case white, black, sky, yellow, pink

    static var saved: PiPTheme {
        PiPTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .black
    }

    var title: String {
        switch self {
        case .white: return L10n.text("白", "White")
        case .black: return L10n.text("黒", "Black")
        case .sky: return L10n.text("水色", "Sky Blue")
        case .yellow: return L10n.text("黄色", "Yellow")
        case .pink: return L10n.text("ピンク", "Pink")
        }
    }

    var color: NSColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .sky: return NSColor(calibratedRed: 0.63, green: 0.85, blue: 1, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1, green: 0.9, blue: 0.52, alpha: 1)
        case .pink: return NSColor(calibratedRed: 1, green: 0.72, blue: 0.82, alpha: 1)
        }
    }

    var foreground: NSColor { self == .black ? .white : NSColor(calibratedWhite: 0.12, alpha: 1) }
    var headerBackground: NSColor { color.withAlphaComponent(self == .black ? 0.4 : 0.85) }

    var pinnedIconColor: NSColor {
        switch self {
        case .white, .sky, .pink: return .white
        case .black: return NSColor(calibratedWhite: 0.12, alpha: 1)
        case .yellow: return tabForeground
        }
    }

    var pinnedBackground: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 0.30, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.88, alpha: 1)
        case .sky, .yellow, .pink: return selectedTabBackground
        }
    }

    // Opaque selection colors keep titles readable even over bright video.
    var selectedTabBackground: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 0.82, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.30, alpha: 1)
        case .sky: return NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.65, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.24, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.68, green: 0.22, blue: 0.40, alpha: 1)
        }
    }

    var selectedTabForeground: NSColor {
        switch self {
        case .black, .sky, .pink: return .white
        case .white, .yellow: return tabForeground
        }
    }

    var tabForeground: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 0.18, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.94, alpha: 1)
        case .sky: return NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.45, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.38, green: 0.27, blue: 0.12, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.42, green: 0.17, blue: 0.27, alpha: 1)
        }
    }

    var appActionColor: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 0.12, alpha: 1)
        case .black: return .white
        case .sky:
            return NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.68, alpha: 1)
        case .yellow:
            return NSColor(calibratedRed: 0.68, green: 0.43, blue: 0.08, alpha: 1)
        case .pink:
            return NSColor(calibratedRed: 0.72, green: 0.24, blue: 0.42, alpha: 1)
        }
    }

    var appBackgroundColor: NSColor {
        switch self {
        case .white: return NSColor(calibratedWhite: 0.98, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.07, alpha: 1)
        case .sky: return NSColor(calibratedRed: 0.94, green: 0.98, blue: 1.00, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.90, alpha: 1)
        case .pink: return NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.97, alpha: 1)
        }
    }

    var appForegroundColor: NSColor {
        switch self {
        case .black: return .white
        case .white: return NSColor(calibratedWhite: 0.10, alpha: 1)
        case .sky: return NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.43, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.37, green: 0.26, blue: 0.11, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.41, green: 0.16, blue: 0.26, alpha: 1)
        }
    }

    func tabBackground(selected: Bool, hovered: Bool) -> NSColor {
        if selected {
            return hovered
                ? selectedTabBackground.blended(withFraction: 0.08, of: selectedTabForeground) ?? selectedTabBackground
                : selectedTabBackground
        }
        return hovered ? tabForeground.withAlphaComponent(0.12) : .clear
    }
}

struct PiplyAppTheme: ViewModifier {
    let theme: PiPTheme

    func body(content: Content) -> some View {
        content
            .tint(Color(nsColor: theme.appActionColor))
            .foregroundStyle(Color(nsColor: theme.appForegroundColor))
            .background(Color(nsColor: theme.appBackgroundColor))
            .preferredColorScheme(theme == .black ? .dark : .light)
    }
}

private struct PiPThemePicker: View {
    @AppStorage(PiPTheme.defaultsKey) private var selected = PiPTheme.black.rawValue

    var body: some View {
        Picker("", selection: $selected) {
            ForEach(PiPTheme.allCases, id: \.rawValue) { theme in
                HStack {
                    Circle()
                        .fill(Color(nsColor: theme.color))
                        .frame(width: 10, height: 10)
                    Text(theme.title)
                }
                .tag(theme.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150, alignment: .trailing)
        .accessibilityLabel(L10n.text("アプリとPiPのテーマ", "App and PiP Theme"))
    }
}
