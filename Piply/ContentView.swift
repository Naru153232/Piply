import SwiftUI

struct ContentView: View {
    @AppStorage(PiPTheme.defaultsKey) private var selectedTheme = PiPTheme.black.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.japanese.rawValue
    @ObservedObject var model: SourcePickerModel
    @State private var chromeTabsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.permissionDenied {
                permissionView
            } else if model.isLoading {
                ProgressView(L10n.text("起動中のウィンドウを取得中…", "Loading Open Windows…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sources.isEmpty && model.chromeTabs.isEmpty {
                ContentUnavailableView(L10n.text("表示できるウィンドウがありません", "No Windows Available"), systemImage: "macwindow", description: Text(L10n.text("ウィンドウを開いてから再読み込みしてください。", "Open a window, then reload.")))
            } else {
                ScrollView {
                  VStack(spacing: 0) {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, canAddTab: model.canAddPiPTab,
                                  action: { model.openPiP(source) },
                                  addAction: { model.openPiP(source, addAsTab: true) })
                            .padding(.vertical, 5)
                        if isChrome(source),
                           source.id == chromeSources.first?.id,
                           model.chromeConnected,
                           !model.chromeTabs.isEmpty {
                            ChromeTabsDisclosure(
                                tabs: model.chromeTabs,
                                action: { tab in model.captureChromeTab(tab) },
                                addAction: { tab in model.captureChromeTab(tab, addAsTab: true) },
                                canAddTab: model.canAddPiPTab,
                                isExpanded: $chromeTabsExpanded
                            )
                        }
                        Divider()
                    }
                  }
                  .padding(.horizontal, 16)
                }
            }
            if let message = model.statusMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .task { await model.start() }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.top, 74)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastMessage)
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? AppLanguage.japanese.locale)
        .modifier(PiplyAppTheme(theme: PiPTheme(rawValue: selectedTheme) ?? .black))
    }

    private var chromeSources: [CaptureSource] {
        model.sources.filter { $0.applicationName.contains("Google Chrome") || $0.applicationName.contains("Chromium") }
    }

    private func isChrome(_ source: CaptureSource) -> Bool {
        source.applicationName.contains("Google Chrome") || source.applicationName.contains("Chromium")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Piply").font(.title2.bold())
                Text(L10n.text("表示したいアプリウィンドウを選択してください", "Choose an app window to display"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Label(L10n.text("設定", "Settings"), systemImage: "gearshape") }
                .buttonStyle(.bordered)
            Button { Task { await model.refresh() } } label: {
                Label(L10n.text("再読み込み", "Reload"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
        }
        .padding()
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 42))
            Text(L10n.text("画面収録の許可が必要です", "Screen Recording Permission Required")).font(.headline)
            Text(L10n.text("システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音で Piply を許可し、アプリを再起動してください。", "Allow Piply in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 430)
            Button(L10n.text("システム設定を開く", "Open System Settings")) { model.openScreenRecordingSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct ChromeTabsDisclosure: View {
    let tabs: [ChromeTab]
    let action: (ChromeTab) -> Void
    let addAction: (ChromeTab) -> Void
    let canAddTab: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Button {
                  withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
              } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack")
                        .font(.body.weight(.medium))
                    Text(L10n.text("Chromeのタブ（\(tabs.count)）", "Chrome Tabs (\(tabs.count))"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(isExpanded ? L10n.text("閉じる", "Close") : L10n.text("開く", "Open"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel(L10n.text("Chromeのタブ一覧", "Chrome Tab List"))
              .accessibilityValue(isExpanded ? L10n.text("開いています", "Expanded") : L10n.text("閉じています", "Collapsed"))
              .accessibilityHint(isExpanded ? L10n.text("押すとタブ一覧を閉じます", "Press to close the tab list") : L10n.text("押すとタブ一覧を開きます", "Press to open the tab list"))
              if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ChromeBlackScreenHelp()
                Text(L10n.text("許可済みのタブは直接PiP表示します。未許可・休止中の場合は選んだタブへ自動で移動します。Chromeの拡張アイコンを1回押すと、そのタブの中だけを表示します。", "Authorized tabs open directly in PiP. For unauthorized or suspended tabs, Piply switches to the selected tab. Click the Chrome extension icon once to display only that tab."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(tabs) { tab in
                        ChromeTabRow(tab: tab, canAddTab: canAddTab,
                                     action: { action(tab) }, addAction: { addAction(tab) })
                        Divider()
                    }
                }
                .padding(.leading, 52)
              }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ChromeBlackScreenHelp: View {
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Chromeの映像が暗くなる場合", "If Chrome Video Appears Dark"))
                .font(.caption.weight(.semibold))
            Text(L10n.text("システム設定の「グラフィック アクセラレーションが使用可能な場合は使用する」（旧称：ハードウェア アクセラレーション）をオフにし、Chromeを再起動して改善するか確認してください。DRM保護映像の表示や暗転の解消を保証するものではありません。オフにすると再生性能が低下する場合があります。", "Turn off “Use graphics acceleration when available” in Chrome's System settings, restart Chrome, and check again. This does not guarantee playback of DRM-protected video or resolve every black screen, and may reduce playback performance."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("Chromeのシステム設定を開く", "Open Chrome System Settings")) {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
                      let url = URL(string: "chrome://settings/system") else {
                    errorMessage = L10n.text("Google Chromeが見つかりません。", "Google Chrome could not be found.")
                    return
                }
                NSWorkspace.shared.open([url], withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    DispatchQueue.main.async {
                        errorMessage = error == nil ? nil : L10n.text("Chromeで chrome://settings/system を開いてください。", "Open chrome://settings/system in Chrome.")
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChromeTabRow: View {
    let tab: ChromeTab
    let canAddTab: Bool
    let action: () -> Void
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "safari")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).lineLimit(1)
                if let url = tab.url { Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if tab.usesProtectedVideo {
                    Label(L10n.text("保護動画：動画PiPを使用", "Protected Video: Use Video PiP"), systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if tab.usesProtectedVideo {
            Button(L10n.text("動画PiPの案内", "Video PiP Help"), action: action)
                .buttonStyle(.borderedProminent)
            } else {
                PiPDisplayMenu(canAddTab: canAddTab, action: action, addAction: addAction)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 18)
    }
}

private struct SourceRow: View {
    let source: CaptureSource
    let canAddTab: Bool
    let action: () -> Void
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: source.icon)
                .resizable().scaledToFit().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).lineLimit(1)
                Text(source.applicationName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PiPDisplayMenu(canAddTab: canAddTab, action: action, addAction: addAction)
        }
        .padding(.vertical, 4)
    }
}

private struct PiPDisplayMenu: View {
    let canAddTab: Bool
    let action: () -> Void
    let addAction: () -> Void

    var body: some View {
        Menu {
            Button(L10n.text("新しいPiPウィンドウで表示", "Show in New PiP Window"), action: action)
            Button(L10n.text("新しいPiPタブに追加", "Add to a New PiP Tab"), action: addAction)
                .disabled(!canAddTab)
        } label: {
            Text(L10n.text("PiPで表示", "Show in PiP"))
        } primaryAction: {
            action()
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help(L10n.text("クリックで新しいPiPウィンドウを作成します。メニューから既存のPiPへタブとして追加できます。", "Click to create a new PiP window. Use the menu to add it as a tab to an existing PiP."))
    }
}

