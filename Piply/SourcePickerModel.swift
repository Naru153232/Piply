import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class SourcePickerModel: ObservableObject {
    @Published private(set) var sources: [CaptureSource] = []
    @Published private(set) var isLoading = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var statusMessage: String?
    @Published var chromeExtensionID = ChromeIntegrationSettings.extensionID
    @Published private(set) var chromeIntegrationInstalled = ChromeIntegrationSettings.isInstalled
    @Published private(set) var chromeConnected = false
    @Published private(set) var chromeExtensionNeedsReload = false
    @Published private(set) var chromeTabs: [ChromeTab] = []
    @Published private(set) var toastMessage: String?
    @Published private(set) var pipTabCount = 0
    @Published private(set) var lastFocusedApplicationName: String?
    var canAddPiPTab: Bool { true }

    private var activePanel: NSWindowController?
    private var activeGroupID: UUID?
    private var activeSelectionKey: String?
    private var activeSelectionByGroup: [UUID: String] = [:]
    private var activeWindowApplicationName: String?
    private struct PiPEntry {
        let key: String
        var title: String
        let controller: NSWindowController
        let applicationName: String?
        var groupID: UUID
    }
    private struct WindowTabRequest { let source: CaptureSource; let groupID: UUID }
    private struct ChromeTabRequest { let tab: ChromeTab; let groupID: UUID }
    private struct TabTransferRequest { let key: String; let groupID: UUID }
    private var pipEntries: [PiPEntry] = []
    private var addingPiPTab = false
    private var requestedGroupID: UUID?
    private var closingAllTabs = false
    private var chromeObserver: NSObjectProtocol?
    private var chromeStateObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var focusedApplicationObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var lastFocusedApplicationProcessID: pid_t?
    private var terminationObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var pendingCapture: (tabID: Int, requestID: String, title: String, started: Date)?
    private var cancelledRequests = Set<String>()

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Termination cannot wait for an async task to enqueue the stop request.
            MainActor.assumeIsolated {
                self?.closeAllPiPTabs()
                self?.cancelPendingCapture()
            }
        }
        chromeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .universalPiPChromeCommand,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleChromeCommand() }
        }
        chromeStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: .universalPiPChromeState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.loadChromeState() }
        }
        activateObserver = DistributedNotificationCenter.default().addObserver(
            forName: .universalPiPActivateExisting,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
        focusedApplicationObserver = NotificationCenter.default.addObserver(
            forName: .universalPiPCaptureFocusedApplication,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let processID = notification.userInfo?["processID"] as? pid_t else { return }
            Task { @MainActor in await self?.openFocusedApplication(processID: processID) }
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.rememberFocusedApplication(application) }
        }
        if let application = NSWorkspace.shared.frontmostApplication {
            rememberFocusedApplication(application)
        }
    }

    deinit {
        if let chromeObserver { DistributedNotificationCenter.default().removeObserver(chromeObserver) }
        if let chromeStateObserver { DistributedNotificationCenter.default().removeObserver(chromeStateObserver) }
        if let activateObserver { DistributedNotificationCenter.default().removeObserver(activateObserver) }
        if let focusedApplicationObserver { NotificationCenter.default.removeObserver(focusedApplicationObserver) }
        if let applicationActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        toastTask?.cancel()
        monitorTask?.cancel()
    }

    func start() async {
        do {
            chromeIntegrationInstalled = try ChromeIntegrationSettings.repairRegistrationIfPossible()
        } catch {
            chromeIntegrationInstalled = false
            statusMessage = L10n.text("Chrome連携の更新に失敗しました: \(error.localizedDescription)", "Failed to update Chrome integration: \(error.localizedDescription)")
        }
        loadChromeState()
        await handleChromeCommand()
        if monitorTask == nil {
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { break }
                    await self?.monitorChromeCapture()
                }
            }
        }
        // Chrome supplies its own permitted tab stream. A cold start from the
        // extension must not block on macOS window-capture permission.
        let fromChrome = ProcessInfo.processInfo.arguments.contains("--chrome-pip")
        guard CGPreflightScreenCaptureAccess() || (!fromChrome && CGRequestScreenCaptureAccess()) else {
            permissionDenied = true
            return
        }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        permissionDenied = false
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            sources = makeSources(from: content)
            .sorted { lhs, rhs in
                lhs.applicationName.localizedCaseInsensitiveCompare(rhs.applicationName) == .orderedAscending
            }
            statusMessage = L10n.text("\(sources.count)個のウィンドウを検出しました", "Found \(sources.count) windows")
        } catch {
            permissionDenied = !CGPreflightScreenCaptureAccess()
            statusMessage = L10n.text("ウィンドウ一覧の取得に失敗しました: \(error.localizedDescription)", "Failed to load the window list: \(error.localizedDescription)")
        }
    }

    private func openFocusedApplication(processID: pid_t) async {
        guard processID != ProcessInfo.processInfo.processIdentifier else {
            showToast(L10n.text("Piply以外のアプリを選択してください", "Select an app other than Piply"))
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            permissionDenied = true
            statusMessage = L10n.text("前面アプリをPiP表示するには画面収録の許可が必要です", "Screen Recording permission is required to show the frontmost app in PiP")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let candidates = makeSources(from: content).filter { $0.window.owningApplication?.processID == processID }
            guard !candidates.isEmpty else {
                showToast(L10n.text("前面アプリに表示できるウィンドウがありません", "The frontmost app has no available windows"))
                return
            }
            let orderedWindowIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]])?.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value } ?? []
            let order = Dictionary(uniqueKeysWithValues: orderedWindowIDs.enumerated().map { ($0.element, $0.offset) })
            let source = candidates.min { order[$0.id, default: .max] < order[$1.id, default: .max] } ?? candidates[0]
            openPiP(source)
        } catch {
            statusMessage = L10n.text("前面アプリのウィンドウ取得に失敗しました: \(error.localizedDescription)", "Failed to load the frontmost app's windows: \(error.localizedDescription)")
        }
    }

    func openLastFocusedApplication() {
        guard let processID = lastFocusedApplicationProcessID else {
            showToast(L10n.text("フォーカス中のアプリが見つかりません", "Could not find the focused app"))
            return
        }
        Task { @MainActor in await openFocusedApplication(processID: processID) }
    }

    private func rememberFocusedApplication(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { return }
        lastFocusedApplicationProcessID = application.processIdentifier
        lastFocusedApplicationName = application.localizedName
    }

    func openPiP(_ source: CaptureSource, addAsTab: Bool = false, targetGroupID: UUID? = nil) {
        addingPiPTab = addAsTab
        requestedGroupID = targetGroupID
        cancelPendingCapture()
        let cropDescription = source.cropRect.map {
            "\($0.minX):\($0.minY):\($0.width):\($0.height)"
        } ?? "full"
        let selectionKey = "window:\(source.id):\(cropDescription)"
        if pipEntries.contains(where: { $0.key == selectionKey }) {
            selectPiPTab(selectionKey)
            return
        }
        let targetPanel = addAsTab ? panelForGroup(targetGroupID ?? activeGroupID) : activePanel
        let previousWindow = targetPanel?.window
        let preferredTopLeft = previousWindow.map {
            addAsTab
                ? NSPoint(x: $0.frame.minX, y: $0.frame.maxY)
                : NSPoint(x: $0.frame.minX + 24, y: $0.frame.maxY - 24)
        }
        let preferredContentWidth = previousWindow?.contentView?.bounds.width
        let groupID = preparePiPTabDestination()
        activeSelectionKey = selectionKey
        activeWindowApplicationName = source.applicationName
        let controller = PiPPanelController(
            source: source,
            selectionKey: selectionKey,
            preferredTopLeft: preferredTopLeft,
            preferredContentWidth: preferredContentWidth
        ) { [weak self] key in
            self?.removePiPTab(key, close: false)
        }
        registerPiPTab(controller, key: selectionKey, title: source.title,
                       applicationName: source.applicationName, groupID: groupID)
        controller.showWindow(nil)
        showToast(L10n.text("「\(source.title)」をPiPで表示しました", "Showing “\(source.title)” in PiP"))
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func installChromeIntegration() {
        do {
            try ChromeIntegrationSettings.install(extensionID: chromeExtensionID)
            chromeIntegrationInstalled = true
            chromeConnected = false
            chromeExtensionNeedsReload = false
            chromeTabs = []
            try? FileManager.default.removeItem(at: ChromeCommandStore.stateFile)
            statusMessage = L10n.text("IDを保存しました。Chromeの拡張機能を再読み込みして接続を確認してください。", "ID saved. Reload the Chrome extension and check the connection.")
        } catch {
            statusMessage = L10n.text("Chrome 連携の設定に失敗しました: \(error.localizedDescription)", "Failed to configure Chrome integration: \(error.localizedDescription)")
        }
    }

    func captureChromeTab(_ tab: ChromeTab, addAsTab: Bool = false, targetGroupID: UUID? = nil) {
        addingPiPTab = addAsTab
        requestedGroupID = targetGroupID
        loadChromeState()
        cancelPendingCapture()
        if tab.usesProtectedVideo {
            statusMessage = L10n.text("DRM保護動画はPiplyへ取得できません。保護されていない動画はChromeの右クリックメニュー「動画をPiPで表示」から選択できます。", "Piply cannot capture DRM-protected video. For unprotected video, choose “Show Video in PiP” from Chrome's context menu.")
            return
        }
        guard chromeConnected, !chromeExtensionNeedsReload else {
            statusMessage = L10n.text("全体画面取得には切り替えません。chrome://extensions で拡張機能を再読み込みしてから、もう一度押してください。", "Piply will not fall back to full-tab capture. Reload the extension at chrome://extensions, then try again.")
            return
        }
        do {
            let requestID = UUID().uuidString
            try ChromeCommandStore.requestCapture(tabID: tab.id, requestID: requestID, addAsTab: addAsTab)
            pendingCapture = (tab.id, requestID, tab.title, Date())
            statusMessage = L10n.text("Chromeタブ「\(tab.title)」を準備しています…", "Preparing Chrome tab “\(tab.title)”…")
        } catch {
            statusMessage = L10n.text("Chromeタブを開けませんでした: \(error.localizedDescription)", "Could not open the Chrome tab: \(error.localizedDescription)")
        }
    }

    private func loadChromeState() {
        guard let state = ChromeCommandStore.loadState(),
              Date().timeIntervalSince1970 - state.connectedAt < 10 else {
            if chromeConnected { chromeConnected = false }
            if !chromeTabs.isEmpty { chromeTabs = [] }
            return
        }
        let connectionChanged = !chromeConnected || chromeExtensionNeedsReload != (state.extensionVersion != "0.9.7")
        if !chromeConnected { chromeConnected = true }
        let needsReload = state.extensionVersion != "0.9.7"
        if chromeExtensionNeedsReload != needsReload { chromeExtensionNeedsReload = needsReload }
        let updatedTabs = state.tabs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if chromeTabs != updatedTabs {
            chromeTabs = updatedTabs
            var titlesChanged = false
            for index in pipEntries.indices {
                if let controller = pipEntries[index].controller as? ChromeTabPiPPanelController,
                   let tab = updatedTabs.first(where: { $0.id == controller.tabID }),
                   pipEntries[index].title != tab.title {
                    pipEntries[index].title = tab.title
                    controller.window?.title = tab.title
                    titlesChanged = true
                }
            }
            if titlesChanged { updatePiPTabBars() }
        }
        if connectionChanged && chromeExtensionNeedsReload {
            statusMessage = L10n.text("Chrome拡張機能を更新しました。chrome://extensions で一度「再読み込み」してください。", "The Chrome extension was updated. Reload it once at chrome://extensions.")
        } else if connectionChanged && chromeIntegrationInstalled {
            statusMessage = L10n.text("Chrome拡張機能との接続を確認しました", "Connected to the Chrome extension")
        }
    }

    func openChromeExtensions() {
        NSWorkspace.shared.open(URL(string: "https://support.google.com/chrome_webstore/answer/2664769?hl=ja")!)
    }

    private func handleChromeCommand() async {
        guard let command = ChromeCommandStore.loadAndConsume() else { return }
        if let id = command.requestId, cancelledRequests.contains(id) { return }
        if let entry = pipEntries.first(where: {
            ($0.controller as? ChromeTabPiPPanelController)?.requestID == command.requestId
        }), let controller = entry.controller as? ChromeTabPiPPanelController {
            switch command.action {
            case "videoWaiting":
                if command.streamId == nil || command.streamId == controller.currentStreamID {
                    controller.setVideoWaiting()
                    if let error = command.error { statusMessage = error }
                }
                return
            case "selectPiPTab": selectPiPTab(entry.key); return
            case "tabCaptureStopped": removePiPTab(entry.key); return
            case "sourceTabClosed": removePiPTab(entry.key); return
            case "streamOffer":
                if let offer = command.sdp, command.streamId != controller.currentStreamID {
                    controller.startStream(offer: offer,
                        viewport: CGSize(width: command.viewportWidth ?? 1280, height: command.viewportHeight ?? 720),
                        streamID: command.streamId, videoElement: command.videoElement == true)
                }
                return
            default: break
            }
        }
        if command.action == "streamOffer", let tabID = command.tabId {
            guard let requestID = command.requestId else { return }
            if pipEntries.contains(where: { ($0.controller as? ChromeTabPiPPanelController)?.tabID == tabID }) {
                openChromeTabPiP(command, tabID: tabID)
                return
            }
            guard pendingCapture == nil || pendingCapture?.requestID == requestID else {
                ChromeCommandStore.requestStopTabCapture(tabID: tabID, requestID: requestID)
                return
            }
            addingPiPTab = command.addAsTab == true
            openChromeTabPiP(command, tabID: tabID)
            return
        }
        if command.action == "captureTabNeedsPermission" {
            guard let requestID = command.requestId,
                  requestID == pendingCapture?.requestID else { return }
            // Waiting for a user invocation is not a failed or timed-out capture.
            // The extension icon will start a fresh request after Chrome grants access.
            pendingCapture = nil
            statusMessage = command.error ?? L10n.text("Chromeで対象タブを開きました。拡張アイコンを1回押すとPiPを開始します。", "The target tab is open in Chrome. Click the extension icon once to start PiP.")
            showToast(L10n.text("「\(command.title)」をChromeで開きました。拡張アイコンを押してください", "Opened “\(command.title)” in Chrome. Click the extension icon."))
            return
        }
        if command.action == "captureTabError" {
            guard command.requestId != nil else { return }
            let failed = pipEntries.first { ($0.controller as? ChromeTabPiPPanelController)?.requestID == command.requestId }
            guard command.requestId == pendingCapture?.requestID || failed != nil else { return }
            if let failed {
                if let controller = failed.controller as? ChromeTabPiPPanelController, controller.retainsVideoTab {
                    controller.reconnectVideo()
                } else { removePiPTab(failed.key) }
            }
            if command.requestId == pendingCapture?.requestID { pendingCapture = nil }
            let reason = command.error.map { "（\($0)）" } ?? ""
            statusMessage = L10n.text("ChromeタブをPiPで表示できませんでした\(reason)", "Could not show the Chrome tab in PiP\(reason)")
            return
        }

        if command.action == "captureTab" {
            statusMessage = L10n.text("古い拡張機能からの全体画面取得を停止しました。chrome://extensions で拡張機能を再読み込みしてください。", "Stopped full-tab capture from an outdated extension. Reload the extension at chrome://extensions.")
        }
    }

    private func openChromeTabPiP(_ command: ChromeCommand, tabID: Int) {
        guard let requestID = command.requestId,
              let offer = command.sdp, !offer.isEmpty else { return }
        let selectionKey = "chrome-tab:\(tabID)"
        if let existing = pipEntries.first(where: { $0.key == selectionKey })?.controller as? ChromeTabPiPPanelController {
            existing.replaceRequest(requestID)
            if pendingCapture?.requestID == requestID { pendingCapture = nil }
            existing.startStream(offer: offer,
                viewport: CGSize(width: command.viewportWidth ?? 1280, height: command.viewportHeight ?? 720),
                streamID: command.streamId, videoElement: command.videoElement == true)
            selectPiPTab(selectionKey)
            return
        }

        let targetPanel = addingPiPTab ? panelForGroup(requestedGroupID ?? activeGroupID) : activePanel
        let previousWindow = targetPanel?.window
        let preferredTopLeft = previousWindow.map {
            addingPiPTab
                ? NSPoint(x: $0.frame.minX, y: $0.frame.maxY)
                : NSPoint(x: $0.frame.minX + 24, y: $0.frame.maxY - 24)
        }
        let preferredContentWidth = previousWindow?.contentView?.bounds.width
        let groupID = preparePiPTabDestination()
        activeSelectionKey = selectionKey
        activeWindowApplicationName = nil

        let contentSize = CGSize(
            width: command.viewportWidth ?? 1280,
            height: command.viewportHeight ?? 720
        )
        let controller = ChromeTabPiPPanelController(
            tabID: tabID,
            requestID: requestID,
            title: command.title,
            contentSize: contentSize,
            selectionKey: selectionKey,
            preferredTopLeft: preferredTopLeft,
            preferredContentWidth: preferredContentWidth
        ) { [weak self] key in
            self?.removePiPTab(key, close: false)
        }
        registerPiPTab(controller, key: selectionKey, title: command.title,
                       applicationName: nil, groupID: groupID)
        controller.onStreamReady = { [weak self] in
            guard let self, self.activeSelectionKey == selectionKey else { return }
            self.statusMessage = L10n.text("Chromeタブ「\(command.title)」をPiPで表示しました", "Showing Chrome tab “\(command.title)” in PiP")
            self.showToast(L10n.text("Chromeタブ「\(command.title)」をPiPで表示しました", "Showing Chrome tab “\(command.title)” in PiP"))
        }
        controller.onStreamError = { [weak self, weak controller] error in
            guard let self else { return }
            if controller?.retainsVideoTab == true { controller?.reconnectVideo() }
            else { controller?.close() }
            self.statusMessage = L10n.text("ChromeタブをPiPで表示できませんでした（\(error)）", "Could not show the Chrome tab in PiP (\(error))")
        }
        pendingCapture = nil
        controller.showWindow(nil)
        statusMessage = L10n.text("Chromeタブ「\(command.title)」の映像に接続しています…", "Connecting to video from Chrome tab “\(command.title)”…")
        controller.startStream(offer: offer, viewport: contentSize,
                               streamID: command.streamId, videoElement: command.videoElement == true)
    }

    private func setPresentation(_ controller: NSWindowController, active: Bool) {
        (controller as? PiPPanelController)?.setPresentationActive(active)
        (controller as? ChromeTabPiPPanelController)?.setPresentationActive(active)
        if !active {
            controller.window?.childWindows?.forEach { $0.orderOut(nil) }
            controller.window?.orderOut(nil)
        }
    }

    private func preparePiPTabDestination() -> UUID {
        let requested = requestedGroupID ?? activeGroupID
        let groupID = addingPiPTab && requested != nil ? requested! : UUID()
        if addingPiPTab, let selected = activeSelectionByGroup[groupID],
           let panel = pipEntries.first(where: { $0.key == selected })?.controller {
            setPresentation(panel, active: false)
        }
        activePanel = nil
        activeSelectionKey = nil
        activeWindowApplicationName = nil
        activeGroupID = groupID
        addingPiPTab = false
        requestedGroupID = nil
        return groupID
    }

    private func registerPiPTab(_ controller: NSWindowController, key: String, title: String,
                                applicationName: String?, groupID: UUID) {
        let entry = PiPEntry(key: key, title: title, controller: controller,
                             applicationName: applicationName, groupID: groupID)
        let insertion = pipEntries.lastIndex(where: { $0.groupID == groupID }).map { $0 + 1 } ?? pipEntries.count
        pipEntries.insert(entry, at: insertion)
        activePanel = controller
        activeGroupID = groupID
        activeSelectionKey = key
        activeSelectionByGroup[groupID] = key
        activeWindowApplicationName = applicationName
        updatePiPTabBars()
    }

    private func updatePiPTabBars() {
        pipTabCount = pipEntries.count
        for entry in pipEntries {
            guard let view = entry.controller.window?.contentView as? PiPContainerView else { continue }
            let groupID = entry.groupID
            let items = pipEntries.filter { $0.groupID == groupID }
                .map { PiPTabItem(id: $0.key, title: $0.title) }
            view.onTabSelected = { [weak self] key in self?.selectPiPTab(key) }
            view.onTabRemoved = { [weak self] key in self?.removePiPTab(key) }
            view.onTabMoved = { [weak self] key, direction in self?.movePiPTab(key, direction: direction) }
            view.onTabTransferMenu = { [weak self] key in self?.makePiPTransferMenu(for: key) }
            view.onTabDropped = { [weak self] key in self?.transferTab(key, to: groupID) ?? false }
            view.onTabDetached = { [weak self] key, point in self?.detachTab(key, at: point) ?? false }
            view.onTabAddMenu = { [weak self] in self?.makePiPAddMenu(groupID: groupID) ?? NSMenu() }
            view.updateTabs(items, selected: activeSelectionByGroup[groupID] ?? "")
        }
    }

    private func makePiPAddMenu(groupID: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for source in sources {
            let item = NSMenuItem(title: "\(source.applicationName) — \(source.title)", action: #selector(addWindowFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WindowTabRequest(source: source, groupID: groupID)
            item.isEnabled = true
            menu.addItem(item)
        }
        if !sources.isEmpty && !chromeTabs.isEmpty { menu.addItem(.separator()) }
        for tab in chromeTabs {
            let item = NSMenuItem(title: "Chrome — \(tab.title)", action: #selector(addChromeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ChromeTabRequest(tab: tab, groupID: groupID)
            item.isEnabled = !tab.usesProtectedVideo && !chromeExtensionNeedsReload
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: L10n.text("表示元がありません。一覧を更新してください", "No sources available. Reload the list."), action: nil, keyEquivalent: "") }
        return menu
    }

    @objc private func addWindowFromMenu(_ item: NSMenuItem) {
        if let request = item.representedObject as? WindowTabRequest {
            openPiP(request.source, addAsTab: true, targetGroupID: request.groupID)
        }
    }

    @objc private func addChromeFromMenu(_ item: NSMenuItem) {
        if let request = item.representedObject as? ChromeTabRequest {
            captureChromeTab(request.tab, addAsTab: true, targetGroupID: request.groupID)
        }
    }

    private func panelForGroup(_ groupID: UUID?) -> NSWindowController? {
        guard let groupID, let selected = activeSelectionByGroup[groupID] else { return nil }
        return pipEntries.first(where: { $0.key == selected })?.controller
    }

    private func makePiPTransferMenu(for key: String) -> NSMenu {
        let menu = NSMenu()
        guard let source = pipEntries.first(where: { $0.key == key }) else { return menu }
        var seen = Set<UUID>()
        for entry in pipEntries where entry.groupID != source.groupID && seen.insert(entry.groupID).inserted {
            let selected = activeSelectionByGroup[entry.groupID]
            let title = pipEntries.first(where: { $0.key == selected })?.title ?? entry.title
            let item = NSMenuItem(title: title, action: #selector(transferTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TabTransferRequest(key: key, groupID: entry.groupID)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func transferTab(_ item: NSMenuItem) {
        guard let request = item.representedObject as? TabTransferRequest else { return }
        _ = transferTab(request.key, to: request.groupID)
    }

    @discardableResult
    private func transferTab(_ key: String, to targetGroupID: UUID,
                             dropTopLeft: NSPoint? = nil) -> Bool {
        guard let sourceIndex = pipEntries.firstIndex(where: { $0.key == key }),
              pipEntries[sourceIndex].groupID != targetGroupID else { return false }

        let sourceGroupID = pipEntries[sourceIndex].groupID
        let sourceController = pipEntries[sourceIndex].controller
        let sourceWindow = sourceController.window
        let sourceTopLeft = sourceWindow.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        let sourceWidth = sourceWindow?.contentView?.bounds.width
        let sourcePinned = (sourceWindow?.contentView as? PiPContainerView)?.isPinned ?? false
        let wasSourceSelected = activeSelectionByGroup[sourceGroupID] == key

        let targetController = panelForGroup(targetGroupID)
        let targetWindow = targetController?.window
        let targetTopLeft = targetWindow.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) } ?? dropTopLeft
        let targetWidth = targetWindow?.contentView?.bounds.width
        let targetPinned = (targetWindow?.contentView as? PiPContainerView)?.isPinned ?? false
        if let targetController { setPresentation(targetController, active: false) }

        pipEntries[sourceIndex].groupID = targetGroupID

        if wasSourceSelected {
            if let replacement = pipEntries.last(where: { $0.groupID == sourceGroupID }) {
                activeSelectionByGroup[sourceGroupID] = replacement.key
                if let window = replacement.controller.window {
                    if let view = window.contentView as? PiPContainerView {
                        PiPGeometry.fit(window, to: view.sourceSize, preferredWidth: sourceWidth)
                        view.setPinned(sourcePinned)
                    }
                    if let sourceTopLeft { window.setFrameTopLeftPoint(sourceTopLeft) }
                }
                setPresentation(replacement.controller, active: true)
                replacement.controller.showWindow(nil)
            } else {
                activeSelectionByGroup.removeValue(forKey: sourceGroupID)
            }
        }

        activeSelectionByGroup[targetGroupID] = key
        activeGroupID = targetGroupID
        activeSelectionKey = key
        activePanel = sourceController
        activeWindowApplicationName = pipEntries[sourceIndex].applicationName
        if let window = sourceWindow {
            if let view = window.contentView as? PiPContainerView {
                PiPGeometry.fit(window, to: view.sourceSize, preferredWidth: targetWidth)
                view.setPinned(targetPinned)
            }
            if let targetTopLeft { window.setFrameTopLeftPoint(targetTopLeft) }
        }
        setPresentation(sourceController, active: true)
        sourceController.showWindow(nil)
        updatePiPTabBars()
        showToast(L10n.text("タブを別のPiPウィンドウへ移動しました", "Moved the tab to another PiP window"))
        return true
    }

    @discardableResult
    private func detachTab(_ key: String, at screenPoint: NSPoint) -> Bool {
        guard let entry = pipEntries.first(where: { $0.key == key }),
              let window = entry.controller.window else { return false }
        // A single-tab PiP is already an independent window. Cancelling the
        // detach lets AppKit animate the dragged tab back to its original spot.
        guard pipEntries.lazy.filter({ $0.groupID == entry.groupID }).prefix(2).count > 1 else {
            return false
        }
        let topLeft = NSPoint(
            x: screenPoint.x - min(80, window.frame.width / 3),
            y: screenPoint.y + PiPContainerView.tabDropOffset
        )
        return transferTab(key, to: UUID(), dropTopLeft: topLeft)
    }

    private func selectPiPTab(_ key: String) {
        guard let entry = pipEntries.first(where: { $0.key == key }) else { return }
        cancelPendingCapture()
        addingPiPTab = false
        requestedGroupID = nil
        let groupID = entry.groupID
        let currentPanel = panelForGroup(groupID)
        let previousWindow = currentPanel?.window
        let topLeft = previousWindow.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        let width = previousWindow?.contentView?.bounds.width
        let pinned = (previousWindow?.contentView as? PiPContainerView)?.isPinned ?? false
        if let current = currentPanel, current !== entry.controller { setPresentation(current, active: false) }
        activePanel = entry.controller
        activeGroupID = groupID
        activeSelectionKey = key
        activeSelectionByGroup[groupID] = key
        activeWindowApplicationName = entry.applicationName
        if let window = entry.controller.window {
            if let view = window.contentView as? PiPContainerView {
                PiPGeometry.fit(window, to: view.sourceSize, preferredWidth: width)
            }
            if let topLeft { window.setFrameTopLeftPoint(topLeft) }
            (window.contentView as? PiPContainerView)?.setPinned(pinned)
        }
        setPresentation(entry.controller, active: true)
        entry.controller.showWindow(nil)
        entry.controller.window?.childWindows?.forEach { $0.orderFront(nil) }
        updatePiPTabBars()
    }

    private func removePiPTab(_ key: String, close: Bool = true) {
        guard let index = pipEntries.firstIndex(where: { $0.key == key }) else { return }
        let removed = pipEntries.remove(at: index)
        let groupID = removed.groupID
        let wasSelected = activeSelectionByGroup[groupID] == key
        if close { removed.controller.close() }
        if wasSelected && !closingAllTabs {
            let remaining = pipEntries.filter { $0.groupID == groupID }
            if let replacement = remaining.last { selectPiPTab(replacement.key) }
            else {
                activeSelectionByGroup.removeValue(forKey: groupID)
                if activeGroupID == groupID {
                    activeGroupID = activeSelectionByGroup.keys.first
                    activeSelectionKey = activeGroupID.flatMap { activeSelectionByGroup[$0] }
                    activePanel = activeSelectionKey.flatMap { selected in
                        pipEntries.first(where: { $0.key == selected })?.controller
                    }
                }
            }
        } else if activeSelectionKey == key {
            if let selected = activeSelectionByGroup[groupID] {
                activeSelectionKey = selected
                activePanel = pipEntries.first(where: { $0.key == selected })?.controller
            } else {
                activePanel = nil
                activeSelectionKey = nil
                activeWindowApplicationName = nil
            }
        }
        updatePiPTabBars()
    }

    private func movePiPTab(_ key: String, direction: Int) {
        guard let entry = pipEntries.first(where: { $0.key == key }) else { return }
        let groupIndices = pipEntries.indices.filter { pipEntries[$0].groupID == entry.groupID }
        guard let position = groupIndices.firstIndex(where: { pipEntries[$0].key == key }),
              groupIndices.indices.contains(position + direction) else { return }
        pipEntries.swapAt(groupIndices[position], groupIndices[position + direction])
        updatePiPTabBars()
    }

    private func closeAllPiPTabs() {
        closingAllTabs = true
        let entries = pipEntries
        pipEntries.removeAll()
        entries.forEach { $0.controller.close() }
        activePanel = nil
        activeGroupID = nil
        activeSelectionKey = nil
        activeSelectionByGroup.removeAll()
        activeWindowApplicationName = nil
        addingPiPTab = false
        closingAllTabs = false
    }

    private func cancelPendingCapture() {
        if let pending = pendingCapture {
            cancelledRequests.insert(pending.requestID)
            ChromeCommandStore.requestStopTabCapture(tabID: pending.tabID, requestID: pending.requestID)
        }
        pendingCapture = nil
    }

    private func monitorChromeCapture() async {
        loadChromeState()
        await handleChromeCommand()
        if let pending = pendingCapture, Date().timeIntervalSince(pending.started) > 30 {
            cancelPendingCapture()
            statusMessage = L10n.text("「\(pending.title)」から画像を受信できませんでした。Chromeの拡張機能が接続されているか確認してください。", "No video was received from “\(pending.title)”. Check that the Chrome extension is connected.")
        }
    }

    private func makeSources(from content: SCShareableContent) -> [CaptureSource] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard let app = window.owningApplication,
                  app.processID != ownPID else { return nil }
            guard window.frame.width >= 100,
                  window.frame.height >= 80,
                  window.windowLayer == 0 else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = (title?.isEmpty == false) ? title! : app.applicationName
            let icon = NSRunningApplication(processIdentifier: app.processID)?.icon ??
                NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
            return CaptureSource(window: window, applicationName: app.applicationName,
                                 title: displayTitle, icon: icon)
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}

extension Notification.Name {
    static let universalPiPCaptureFocusedApplication = Notification.Name("com.example.UniversalPiP.CaptureFocusedApplication")
    static let universalPiPChromeCommand = Notification.Name("com.example.UniversalPiP.ChromeCommand")
    static let universalPiPChromeState = Notification.Name("com.example.UniversalPiP.ChromeState")
    static let universalPiPChromeFrame = Notification.Name("com.example.UniversalPiP.ChromeFrame")
    static let universalPiPActivateExisting = Notification.Name("com.example.UniversalPiP.ActivateExisting")
}

