import AppKit
import SwiftUI

private extension NSPasteboard.PasteboardType {
    static let pipTab = NSPasteboard.PasteboardType("com.piply.pip-tab")
}

// Xcode Canvasのプレビューを見ながら、この値を編集すると実際のPiPにも反映されます。
private enum PiPToolbarStyle {
    static let iconSize: CGFloat = 10
    static let pinIconSize: CGFloat = 12
    static let buttonSize: CGFloat = 24
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let spacing: CGFloat = 4
    static let cornerRadius: CGFloat = 12
    static var width: CGFloat { buttonSize * 2 + horizontalPadding * 2 + spacing }
    static var height: CGFloat { buttonSize + verticalPadding * 2 }

    static func icon(_ symbol: String, size: CGFloat? = nil) -> NSImage? {
        let iconSize = size ?? (symbol == "pin" || symbol == "pin.fill" ? pinIconSize : Self.iconSize)
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)) else { return nil }
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width / source.size.width, rect.height / source.size.height)
            let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: (rect.width - fitted.width) / 2,
                                  y: (rect.height - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class PiPSeekTimeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PiPControlsOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PiPSeekSlider: NSSlider {
    private(set) var isTrackingPosition = false
    var onTrackingChanged: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.orderFrontRegardless()
        isTrackingPosition = true
        onTrackingChanged?(true)
        defer {
            isTrackingPosition = false
            onTrackingChanged?(false)
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

struct PiPTabItem {
    let id: String
    let title: String
}

final class PiPContainerView: NSView {
    private static let tabHeaderHeight: CGFloat = 28
    static let tabDropOffset: CGFloat = 14
    private static let mediaButtonSize: CGFloat = 52
    private static let mediaIconSize: CGFloat = 28
    private static let mediaButtonSpacing: CGFloat = 20
    private static let auxiliaryMediaButtonSize: CGFloat = 26
    private static let auxiliaryMediaIconSize: CGFloat = 14
    private var tabDisplayMode = PiPTabDisplayMode.saved
    private var tabTheme = PiPTheme.saved
    private let tabBar = NSView()
    private let tabScrollView = PiPTabScrollView()
    private var selectedTabID: String?
    private var tabButtons: [NSButton] = []
    private var addTabButton: NSButton?
    private var resizeStartSize: NSSize?
    private var resizeSourceSize: CGSize?
    private var resizeUsesHeight: Bool?
    private let headerBackground = NSView()
    private var toolTop: NSLayoutConstraint!
    private var toolHeight: NSLayoutConstraint!
    private var streamSurface: NSView?
    private var videoWaiting = false
    private let waitingBackground = NSView()
    private let controlsOverlay = PiPControlsOverlayView()
    private(set) var headerHeight: CGFloat = 0
    var sourceSize: CGSize = CGSize(width: 16, height: 9)
    var onTabSelected: ((String) -> Void)?
    var onTabRemoved: ((String) -> Void)?
    var onTabMoved: ((String, Int) -> Void)?
    var onTabTransferMenu: ((String) -> NSMenu?)?
    var onTabDropped: ((String) -> Bool)?
    var onTabDetached: ((String, NSPoint) -> Bool)?
    var onTabAddMenu: (() -> NSMenu)?
    let preview = CapturePreviewView(frame: .zero)
    private let toolMenu = NSView(frame: .zero)
    private let pinButton = PiPToolButton(frame: .zero)
    private var pinHovered = false
    private let closeButton = PiPToolButton(frame: .zero)
    private let pinnedBadge = NSImageView(frame: .zero)
    private let mediaMenu = NSStackView()
    private var mediaWidthConstraint: NSLayoutConstraint!
    private let seekSlider = PiPSeekSlider()
    private let seekRow = NSStackView()
    private let buttonRow = NSStackView()
    private let seekTimePopup = PiPSeekTimeLabel(labelWithString: "0:00")
    private var mediaButtonSizes: [(constraint: NSLayoutConstraint, baseSize: CGFloat)] = []
    private var seekRowWidth: NSLayoutConstraint!
    private var mediaBottom: NSLayoutConstraint!
    private var buttonCenterY: NSLayoutConstraint!
    private var mediaScale: CGFloat = 1
    private var durationText = "—"
    private var mediaSymbols = ["gobackward.10", "play.fill", "goforward.10", "speaker.wave.2.fill"]
    private let timeLabel = NSTextField(labelWithString: "0:00 / —")
    private var mediaButtons: [PiPToolButton] = []
    private var hasVideoControls = false
    var onVideoControl: ((String) -> Void)?
    var onVideoSeek: ((Double) -> Void)?
    private let closeTarget: ClosureTarget
    private let onPinChanged: (Bool) -> Void
    private var trackingAreaReference: NSTrackingArea?
    private let resizeEdgeWidth: CGFloat = 8
    private let resizeCornerSize: CGFloat = 18
    private var isPointerInside = false
    private var toolbarPreviewOnly = false
    private var pendingHide: DispatchWorkItem?
    private var toolsVisible = false
    private(set) var isPinned = false

    // macOS 14 has no public diagonal frame-resize cursor. Cache native symbol
    // cursors there; macOS 15 and later use the system's frame-resize cursors.
    private static let diagonalDownCursor = diagonalCursor(symbol: "arrow.up.left.and.arrow.down.right")
    private static let diagonalUpCursor = diagonalCursor(symbol: "arrow.up.right.and.arrow.down.left")

    init(onClose: @escaping () -> Void, onPinChanged: @escaping (Bool) -> Void) {
        closeTarget = ClosureTarget(action: onClose)
        self.onPinChanged = onPinChanged
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 0
        layer?.cornerRadius = 0
        layer?.masksToBounds = true

        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = bounds
        preview.autoresizingMask = []
        addSubview(preview)
        waitingBackground.wantsLayer = true
        waitingBackground.isHidden = true
        addSubview(waitingBackground)
        controlsOverlay.wantsLayer = true
        controlsOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        controlsOverlay.alphaValue = 0
        addSubview(controlsOverlay)

        toolMenu.translatesAutoresizingMaskIntoConstraints = false
        toolMenu.wantsLayer = true
        toolMenu.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.82).cgColor
        toolMenu.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        toolMenu.layer?.borderWidth = 0.75
        toolMenu.layer?.cornerRadius = PiPToolbarStyle.cornerRadius
        toolMenu.layer?.shadowColor = NSColor.black.cgColor
        toolMenu.layer?.shadowOpacity = 0.28
        toolMenu.layer?.shadowRadius = 7
        toolMenu.layer?.shadowOffset = CGSize(width: 0, height: -2)
        toolMenu.alphaValue = 0
        addSubview(toolMenu)

        pinnedBadge.translatesAutoresizingMaskIntoConstraints = false
        pinnedBadge.image = PiPToolbarStyle.icon("pin.fill")
        pinnedBadge.imageScaling = .scaleNone
        pinnedBadge.contentTintColor = NSColor(calibratedRed: 0.48, green: 0.76, blue: 1, alpha: 1)
        pinnedBadge.wantsLayer = true
        pinnedBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.82).cgColor
        pinnedBadge.layer?.cornerRadius = 12
        pinnedBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        pinnedBadge.layer?.borderWidth = 0.75
        pinnedBadge.alphaValue = 0
        pinnedBadge.setAccessibilityLabel(L10n.text("位置固定中", "Position Locked"))
        addSubview(pinnedBadge)

        configureToolButton(pinButton, symbol: "pin", description: L10n.text("位置を固定", "Lock Position"))
        pinButton.target = self
        pinButton.action = #selector(togglePin)

        configureToolButton(closeButton, symbol: "xmark", description: L10n.text("閉じる", "Close"))
        closeButton.target = closeTarget
        closeButton.action = #selector(ClosureTarget.invoke)
        pinButton.toolTip = L10n.text("位置を固定", "Lock Position")
        closeButton.toolTip = L10n.text("PiPを閉じる", "Close PiP")
        pinButton.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering { self.showTools() }
            self.pinHovered = hovering
            self.updatePinAppearance()
        }
        closeButton.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering { self.showTools() }
            self.closeButton.layer?.backgroundColor = hovering
                ? self.tabTheme.tabForeground.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
        toolMenu.addSubview(pinButton)
        toolMenu.addSubview(closeButton)

        toolTop = toolMenu.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        toolHeight = toolMenu.heightAnchor.constraint(equalToConstant: PiPToolbarStyle.height)
        NSLayoutConstraint.activate([
            pinnedBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pinnedBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinnedBadge.widthAnchor.constraint(equalToConstant: 24),
            pinnedBadge.heightAnchor.constraint(equalToConstant: 24),
            toolTop,
            toolMenu.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolMenu.widthAnchor.constraint(equalToConstant: PiPToolbarStyle.width),
            toolHeight,
            pinButton.leadingAnchor.constraint(equalTo: toolMenu.leadingAnchor, constant: PiPToolbarStyle.horizontalPadding),
            pinButton.centerYAnchor.constraint(equalTo: toolMenu.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: PiPToolbarStyle.buttonSize),
            pinButton.heightAnchor.constraint(equalToConstant: PiPToolbarStyle.buttonSize),
            closeButton.trailingAnchor.constraint(equalTo: toolMenu.trailingAnchor, constant: -PiPToolbarStyle.horizontalPadding),
            closeButton.centerYAnchor.constraint(equalTo: toolMenu.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: PiPToolbarStyle.buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: PiPToolbarStyle.buttonSize)
        ])
        mediaMenu.orientation = .vertical
        mediaMenu.spacing = PiPToolbarStyle.spacing
        mediaMenu.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        mediaMenu.translatesAutoresizingMaskIntoConstraints = false
        mediaMenu.wantsLayer = true
        mediaMenu.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        mediaMenu.layer?.cornerRadius = 10
        mediaMenu.layer?.borderWidth = 0
        mediaMenu.alphaValue = 0
        addSubview(mediaMenu)
        seekRow.orientation = .horizontal
        seekRow.spacing = 8
        seekSlider.controlSize = .small
        seekSlider.isContinuous = true
        seekSlider.target = self
        seekSlider.action = #selector(seekVideo)
        seekSlider.isEnabled = false
        seekSlider.setAccessibilityLabel(L10n.text("動画の再生位置", "Video Playback Position"))
        seekSlider.toolTip = L10n.text("クリックまたはドラッグして再生位置を選択", "Click or drag to choose a playback position")
        seekSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            if tracking {
                self.showTools()
                self.updateSeekPreview()
            } else {
                self.seekTimePopup.isHidden = true
                self.onVideoSeek?(self.seekSlider.doubleValue)
                if let window = self.window {
                    let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                    if !self.bounds.contains(point) { self.hideTools() }
                }
            }
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        timeLabel.textColor = .black
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        seekRow.addArrangedSubview(seekSlider)
        seekRow.addArrangedSubview(timeLabel)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = Self.mediaButtonSpacing
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.wantsLayer = true
        buttonRow.layer?.backgroundColor = NSColor.clear.cgColor
        buttonRow.layer?.borderWidth = 0
        buttonRow.alphaValue = 0
        addSubview(buttonRow)
        mediaMenu.addArrangedSubview(seekRow)
        seekRowWidth = seekRow.widthAnchor.constraint(equalTo: mediaMenu.widthAnchor, constant: -16)
        seekRowWidth.isActive = true
        let items = [("gobackward.10", L10n.text("10秒戻す", "Back 10 Seconds")), ("play.fill", L10n.text("再生", "Play")),
                     ("goforward.10", L10n.text("10秒進む", "Forward 10 Seconds")), ("speaker.wave.2.fill", L10n.text("消音", "Mute"))]
        for (index, item) in items.enumerated() {
            let button = PiPToolButton(frame: .zero)
            configureToolButton(button, symbol: item.0, description: item.1)
            button.toolTip = item.1
            button.tag = index
            button.target = self
            button.action = #selector(controlVideo(_:))
            button.onHoverChanged = { [weak self, weak button] hovering in
                if hovering { self?.showTools() }
                button?.layer?.backgroundColor = hovering
                    ? self?.tabTheme.tabForeground.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            }
            if index < 3 { buttonRow.addArrangedSubview(button) }
            else { seekRow.addArrangedSubview(button) }
            let buttonSize = index < 3 ? Self.mediaButtonSize : Self.auxiliaryMediaButtonSize
            let iconSize = index < 3 ? Self.mediaIconSize : Self.auxiliaryMediaIconSize
            button.image = PiPToolbarStyle.icon(item.0, size: iconSize)
            let sizes = [button.widthAnchor.constraint(equalToConstant: buttonSize),
                         button.heightAnchor.constraint(equalToConstant: buttonSize)]
            NSLayoutConstraint.activate(sizes)
            mediaButtonSizes.append(contentsOf: sizes.map { ($0, buttonSize) })
            mediaButtons.append(button)
        }
        // Keep media controls independent of the window's minimum width.
        mediaWidthConstraint = mediaMenu.widthAnchor.constraint(equalToConstant: 380)
        mediaBottom = mediaMenu.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        // Keep playback controls independent from the bottom timeline and pin
        // them to the exact center of the visible video surface.
        buttonCenterY = buttonRow.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            mediaWidthConstraint,
            mediaMenu.centerXAnchor.constraint(equalTo: centerXAnchor),
            mediaBottom,
            buttonRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonCenterY
        ])
        tabBar.wantsLayer = true
        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        headerBackground.isHidden = true
        addSubview(headerBackground, positioned: .below, relativeTo: toolMenu)
        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.horizontalScrollElasticity = .none
        tabScrollView.verticalScrollElasticity = .none
        tabScrollView.contentView.drawsBackground = false
        tabScrollView.documentView = tabBar
        addSubview(tabScrollView)
        seekTimePopup.alignment = .center
        seekTimePopup.wantsLayer = true
        seekTimePopup.layer?.cornerRadius = 5
        seekTimePopup.layer?.masksToBounds = true
        seekTimePopup.isHidden = true
        addSubview(seekTimePopup)
        NotificationCenter.default.addObserver(self, selector: #selector(tabModeChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        registerForDraggedTypes([.pipTab])
        applyTabMode()
        applyTheme()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func tabModeChanged() {
        if PiPTheme.saved != tabTheme {
            tabTheme = PiPTheme.saved
            applyTheme()
        }
        guard PiPTabDisplayMode.saved != tabDisplayMode else { return }
        // Preferences can be delivered during a live drag; apply after it ends.
        guard window?.inLiveResize != true else { return }
        tabDisplayMode = PiPTabDisplayMode.saved
        applyTabMode()
    }

    private func applyTabMode() {
        let newHeight: CGFloat = tabDisplayMode == .always ? Self.tabHeaderHeight : 0
        let changed = headerHeight != newHeight
        let origin = window?.frame.origin
        headerHeight = newHeight
        toolTop.constant = 0
        toolHeight.constant = Self.tabHeaderHeight
        toolMenu.layer?.backgroundColor = NSColor.clear.cgColor
        toolMenu.layer?.borderWidth = 0
        toolMenu.layer?.shadowOpacity = 0
        pinButton.image = PiPToolbarStyle.icon(isPinned ? "pin.fill" : "pin", size: 12)
        closeButton.image = PiPToolbarStyle.icon("xmark", size: 12)
        if let window {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            toolsVisible = bounds.contains(point)
            isPointerInside = toolsVisible
            if changed {
                PiPGeometry.fit(window, to: sourceSize)
                if let origin { window.setFrameOrigin(origin) }
            }
        }
        updateHeaderVisibility()
        layoutMediaSurface()
    }

    private func applyTheme() {
        headerBackground.layer?.backgroundColor = tabTheme.headerBackground.cgColor
        waitingBackground.layer?.backgroundColor = tabTheme.headerBackground.cgColor
        updatePinAppearance()
        closeButton.contentTintColor = tabTheme.tabForeground
        addTabButton?.contentTintColor = tabTheme.tabForeground
        pinnedBadge.contentTintColor = tabTheme.pinnedIconColor
        pinnedBadge.layer?.backgroundColor = tabTheme.pinnedBackground.cgColor
        for button in mediaButtons + [closeButton] {
            button.layer?.backgroundColor = tabTheme.tabForeground.withAlphaComponent(
                button.isHovered ? 0.14 : 0).cgColor
        }
        // The compact timeline uses the same neutral white card in every theme.
        // Centered playback buttons float directly over the picture.
        mediaMenu.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        buttonRow.layer?.backgroundColor = NSColor.clear.cgColor
        timeLabel.textColor = .black
        seekTimePopup.textColor = .black
        seekTimePopup.layer?.backgroundColor = NSColor.white.cgColor
        for (index, button) in mediaButtons.enumerated() {
            // Playback controls float over the video, so use a stable white
            // tint instead of inheriting colors from the selected app theme.
            button.contentTintColor = index < 3 ? .white : .black
        }
        for button in tabButtons {
            (button as? PiPTabButton)?.applyTheme(tabTheme, selected: button.identifier?.rawValue == selectedTabID)
        }
    }

    private func updateHeaderVisibility() {
        let visible = tabDisplayMode == .always || toolsVisible || toolbarPreviewOnly
        headerBackground.isHidden = !visible
        tabScrollView.isHidden = !visible
        toolMenu.isHidden = !visible
        toolMenu.alphaValue = visible ? 1 : 0
        pinnedBadge.alphaValue = 0
    }

    func updateTabs(_ tabs: [PiPTabItem], selected: String) {
        let selectionChanged = selectedTabID != selected
        selectedTabID = selected
        tabModeChanged()
        updateHeaderVisibility()
        for view in tabBar.subviews { view.removeFromSuperview() }
        tabButtons.removeAll()
        addTabButton = nil
        for (index, tab) in tabs.enumerated() {
            let button = PiPTabButton(frame: .zero)
            button.onCloseTab = { [weak self] in self?.onTabRemoved?(tab.id) }
            button.isBordered = false
            button.title = tab.title
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.applyTheme(tabTheme, selected: tab.id == selected)
            button.cell?.lineBreakMode = .byTruncatingTail
            // Long page titles must truncate inside the bar, never enlarge PiP.
            button.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.identifier = NSUserInterfaceItemIdentifier(tab.id)
            button.dragIdentifier = tab.id
            button.onDetach = { [weak self] key, point in self?.onTabDetached?(key, point) ?? false }
            button.target = self
            button.action = #selector(selectTab(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 0
            button.toolTip = L10n.text("\(tab.title) — クリックで切替、別のPiPへドラッグして移動", "\(tab.title) — Click to switch, or drag to another PiP")
            button.setAccessibilityLabel(tab.title)
            button.onHoverChanged = { [weak self] hover in
                if hover { self?.showTools() }
            }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action, offset) in [(L10n.text("左へ移動", "Move Left"), #selector(moveTab(_:)), -1),
                                            (L10n.text("右へ移動", "Move Right"), #selector(moveTab(_:)), 1),
                                            (L10n.text("このPiPタブを削除", "Remove This PiP Tab"), #selector(removeTab(_:)), 0)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = tab.id
                item.tag = offset
                item.isEnabled = offset == 0 || (index + offset >= 0 && index + offset < tabs.count)
                menu.addItem(item)
            }
            if let transferMenu = onTabTransferMenu?(tab.id), !transferMenu.items.isEmpty {
                menu.insertItem(.separator(), at: 2)
                let transfer = NSMenuItem(title: L10n.text("別のPiPウィンドウへ移動", "Move to Another PiP Window"), action: nil, keyEquivalent: "")
                transfer.submenu = transferMenu
                menu.insertItem(transfer, at: 3)
            }
            button.menu = menu
            tabBar.addSubview(button)
            tabButtons.append(button)
        }
        let add = PiPToolButton(frame: .zero)
        add.isBordered = false
        add.image = PiPToolbarStyle.icon("plus")
        add.contentTintColor = tabTheme.tabForeground
        add.toolTip = L10n.text("表示元を選んで新しいPiPタブに追加", "Choose a Source to Add a New PiP Tab")
        add.setAccessibilityLabel(L10n.text("PiPタブを追加", "Add PiP Tab"))
        add.target = self
        add.action = #selector(addTab(_:))
        add.onHoverChanged = { [weak self] hover in if hover { self?.showTools() } }
        tabBar.addSubview(add)
        addTabButton = add
        layoutMediaSurface()
        if selectionChanged, let button = tabButtons.first(where: { $0.identifier?.rawValue == selected }) {
            var target = button.frame
            target.size.width = min(target.width, tabScrollView.contentView.bounds.width)
            tabBar.scrollToVisible(target)
        }
    }

    @objc private func selectTab(_ button: NSButton) {
        if let id = button.identifier?.rawValue { onTabSelected?(id) }
    }
    @objc private func removeTab(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onTabRemoved?(id) }
    }
    @objc private func moveTab(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onTabMoved?(id, item.tag) }
    }
    @objc private func addTab(_ button: NSButton) {
        onTabAddMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    func setPinned(_ pinned: Bool) {
        if pinned != isPinned { togglePin() }
    }

    func updateVideoControls(_ state: PiPVideoState) {
        let paused = state.paused, muted = state.muted
        hasVideoControls = !videoWaiting
        durationText = state.duration.map(Self.formatTime) ?? "LIVE"
        // Do not let incoming playback updates move the thumb under the mouse.
        if !seekSlider.isTrackingPosition {
            let start = state.seekStart ?? 0
            let end = state.seekEnd ?? 0
            seekSlider.isEnabled = end > start
            seekSlider.minValue = start
            seekSlider.maxValue = max(start + 0.001, end)
            seekSlider.doubleValue = max(start, min(end, state.currentTime))
            timeLabel.stringValue = "\(Self.formatTime(state.currentTime)) / \(state.duration.map(Self.formatTime) ?? "LIVE")"
        }
        mediaSymbols[1] = paused ? "play.fill" : "pause.fill"
        mediaButtons[1].image = PiPToolbarStyle.icon(mediaSymbols[1], size: Self.mediaIconSize * mediaScale)
        mediaButtons[1].toolTip = paused ? L10n.text("再生", "Play") : L10n.text("一時停止", "Pause")
        mediaButtons[1].setAccessibilityLabel(mediaButtons[1].toolTip)
        mediaSymbols[3] = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        mediaButtons[3].image = PiPToolbarStyle.icon(
            mediaSymbols[3],
            size: Self.auxiliaryMediaIconSize * mediaScale
        )
        mediaButtons[3].toolTip = muted ? L10n.text("消音を解除", "Unmute") : L10n.text("消音", "Mute")
        mediaButtons[3].setAccessibilityLabel(mediaButtons[3].toolTip)
        mediaMenu.alphaValue = toolsVisible && hasVideoControls ? 1 : 0
        buttonRow.alphaValue = toolsVisible && hasVideoControls ? 1 : 0
    }

    private static func formatTime(_ value: Double) -> String {
        let seconds = Int(min(max(value, 0), 35999999))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func seekVideo() {
        guard seekSlider.isEnabled else { return }
        updateSeekPreview()
        // Keep dragging lightweight; commit to the video when the pointer is
        // released. Keyboard and accessibility changes commit immediately.
        if !seekSlider.isTrackingPosition { onVideoSeek?(seekSlider.doubleValue) }
    }

    private func updateSeekPreview() {
        let time = Self.formatTime(seekSlider.doubleValue)
        timeLabel.stringValue = "\(time) / \(durationText)"
        guard seekSlider.isTrackingPosition else { return }
        seekTimePopup.stringValue = time
        seekTimePopup.font = .monospacedDigitSystemFont(ofSize: max(10, 11 * mediaScale), weight: .medium)
        let textSize = (time as NSString).size(withAttributes: [.font: seekTimePopup.font!])
        let size = NSSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 8)
        let knob = (seekSlider.cell as? NSSliderCell)?.knobRect(flipped: seekSlider.isFlipped) ?? seekSlider.bounds
        let rect = convert(knob, from: seekSlider)
        seekTimePopup.frame = NSRect(x: min(max(0, rect.midX - size.width / 2), max(0, bounds.width - size.width)),
                                    y: min(rect.maxY + 5, max(0, bounds.height - size.height)),
                                    width: size.width, height: size.height)
        seekTimePopup.isHidden = false
    }

    @objc private func controlVideo(_ sender: NSButton) {
        onVideoControl?(["back", "toggle", "forward", "mute"][sender.tag])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        guard !isPinned else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Keep the drag hit area in sync with the resize cursor hit area.
        // In particular, corners use a wider target than straight edges; the
        // old rectangular inset started a window move in part of that target.
        guard resizePosition(at: point) == nil else {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }

    func beginResize() {
        resizeStartSize = window?.frame.size
        resizeSourceSize = sourceSize
        resizeUsesHeight = nil
    }

    func endResize() {
        resizeStartSize = nil
        resizeSourceSize = nil
        resizeUsesHeight = nil
        tabModeChanged()
    }

    func constrainedResize(_ proposed: NSSize) -> NSSize {
        if resizeStartSize == nil { beginResize() }
        let source = resizeSourceSize ?? sourceSize
        guard source.width > 0, source.height > 0 else { return proposed }
        let ratio = source.width / source.height
        let start = resizeStartSize ?? proposed
        // Select the driving dimension once. Re-selecting it from each
        // corrected frame causes top-edge drags to alternate width/height.
        if resizeUsesHeight == nil {
            let dx = abs(proposed.width - start.width)
            let dy = abs(proposed.height - start.height) * ratio
            if max(dx, dy) > 0.5 { resizeUsesHeight = dy > dx }
        }
        let width = resizeUsesHeight == true
            ? (proposed.height - headerHeight) * ratio : proposed.width
        return NSSize(width: max(PiPGeometry.minimumWidth, width), height: max(PiPGeometry.minimumWidth, width) / ratio + headerHeight)
    }

    func resumeVideoSurface() {
        // WebKit must be visible to deliver the first decoded-frame callback.
        // Keep the placeholder above it until that callback arrives.
        streamSurface?.isHidden = false
    }

    func setVideoWaiting(_ waiting: Bool) {
        videoWaiting = waiting
        waitingBackground.isHidden = !waiting
        streamSurface?.isHidden = waiting
        if waiting {
            hasVideoControls = false
            mediaMenu.alphaValue = 0
            buttonRow.alphaValue = 0
            seekTimePopup.isHidden = true
            seekSlider.isEnabled = false
        }
    }

    func installStreamView(_ view: NSView) {
        preview.isHidden = true
        if streamSurface !== view { streamSurface?.removeFromSuperview() }
        streamSurface = view
        view.isHidden = videoWaiting
        view.autoresizingMask = []
        addSubview(view, positioned: .below, relativeTo: waitingBackground)
        layoutMediaSurface()
    }

    fileprivate func configureToolbarPreview(pinned: Bool) {
        toolbarPreviewOnly = true
        preview.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        if pinned != isPinned { togglePin() }
        showTools()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        layoutMediaSurface()
        toolMenu.layer?.shadowPath = CGPath(
            roundedRect: toolMenu.bounds,
            cornerWidth: PiPToolbarStyle.cornerRadius,
            cornerHeight: PiPToolbarStyle.cornerRadius,
            transform: nil
        )
        if seekSlider.isTrackingPosition { updateSeekPreview() }
        // Automatic aspect changes and user resizing both move the hit regions.
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMediaSurface()
    }

    private func acceptsTabDrop(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.string(forType: .pipTab) != nil else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        return point.y >= bounds.maxY - max(Self.tabHeaderHeight, 36)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop(sender) else { return [] }
        window?.orderFrontRegardless()
        showTools()
        tabBar.wantsLayer = true
        tabBar.layer?.borderColor = tabTheme.appActionColor.cgColor
        tabBar.layer?.borderWidth = 2
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsTabDrop(sender) ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        tabBar.layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { tabBar.layer?.borderWidth = 0 }
        guard acceptsTabDrop(sender),
              let key = sender.draggingPasteboard.string(forType: .pipTab) else { return false }
        return onTabDropped?(key) ?? false
    }

    private func layoutMediaSurface() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mediaHeight = max(0, bounds.height - headerHeight)
        let scale = min(1.7, max(0.67, min(bounds.width / 480, mediaHeight / 270)))
        if abs(scale - mediaScale) > 0.01 {
            mediaScale = scale
            for item in mediaButtonSizes { item.constraint.constant = item.baseSize * scale }
            mediaMenu.edgeInsets = NSEdgeInsets(top: 4 * scale, left: 8 * scale, bottom: 4 * scale, right: 8 * scale)
            mediaMenu.spacing = 6 * scale
            buttonRow.spacing = Self.mediaButtonSpacing * scale
            seekRow.spacing = 6 * scale
            seekRowWidth?.constant = -16 * scale
            mediaBottom?.constant = -6 * scale
            timeLabel.font = .monospacedDigitSystemFont(ofSize: max(8, 9 * scale), weight: .regular)
            seekSlider.controlSize = scale < 1 ? .mini : .small
            for (index, button) in mediaButtons.enumerated() {
                let iconSize = index < 3 ? Self.mediaIconSize : Self.auxiliaryMediaIconSize
                button.image = PiPToolbarStyle.icon(mediaSymbols[index], size: iconSize * scale)
                button.layer?.cornerRadius = 8 * scale
            }
        }
        timeLabel.isHidden = bounds.width < 200
        mediaMenu.isHidden = mediaHeight < 32 * scale
        buttonRow.isHidden = mediaHeight < 68 * scale
        // The optional tab header sits above the video. Offset by half its
        // height so the controls remain centered on the picture itself.
        buttonCenterY?.constant = -headerHeight / 2
        let mediaWidth = max(84, min(640, bounds.width - 12 * scale))
        if let mediaWidthConstraint, mediaWidthConstraint.constant != mediaWidth {
            mediaWidthConstraint.constant = mediaWidth
        }
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        preview.frame = rect
        waitingBackground.frame = rect
        controlsOverlay.frame = rect
        streamSurface?.frame = rect
        headerBackground.frame = NSRect(x: 0, y: bounds.maxY - Self.tabHeaderHeight,
                                        width: bounds.width, height: Self.tabHeaderHeight)
        let available = max(0, bounds.width - PiPToolbarStyle.width)
        let scrollX = tabScrollView.contentView.bounds.minX
        tabScrollView.frame = NSRect(x: 0, y: bounds.maxY - Self.tabHeaderHeight,
                                     width: available, height: Self.tabHeaderHeight)
        let addWidth: CGFloat = addTabButton == nil ? 0 : 28
        // Keep every tab reachable as the group grows. Titles still truncate,
        // and horizontal scrolling remains available at the minimum width.
        let preferredTabWidth: CGFloat = 160
        let minimumTabWidth: CGFloat = 72
        let naturalWidth = available > addWidth
            ? (available - addWidth) / max(CGFloat(tabButtons.count), 1)
            : minimumTabWidth
        let tabWidth = max(minimumTabWidth, min(preferredTabWidth, naturalWidth))
        let documentWidth = max(available, CGFloat(tabButtons.count) * tabWidth + addWidth)
        tabBar.frame = NSRect(x: 0, y: 0, width: documentWidth, height: Self.tabHeaderHeight)
        tabScrollView.contentView.scroll(to: NSPoint(x: min(scrollX, max(0, documentWidth - available)), y: 0))
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
        for (index, button) in tabButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: tabBar.bounds.height)
        }
        addTabButton?.frame = NSRect(x: CGFloat(tabButtons.count) * tabWidth, y: 0,
                                    width: addWidth, height: tabBar.bounds.height)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isPointerInside { addCursorRect(toolMenu.frame, cursor: .pointingHand) }
        guard !isPinned else { return }
        guard bounds.width > resizeCornerSize * 2,
              bounds.height > resizeCornerSize * 2 else { return }

        let edgeWidth = resizeEdgeWidth
        let cornerSize = resizeCornerSize
        let horizontalLength = bounds.width - cornerSize * 2
        let verticalLength = bounds.height - cornerSize * 2

        addCursorRect(
            NSRect(x: cornerSize, y: bounds.maxY - edgeWidth, width: horizontalLength, height: edgeWidth),
            cursor: resizeCursor(for: .top)
        )
        addCursorRect(
            NSRect(x: cornerSize, y: bounds.minY, width: horizontalLength, height: edgeWidth),
            cursor: resizeCursor(for: .bottom)
        )
        addCursorRect(
            NSRect(x: bounds.minX, y: cornerSize, width: edgeWidth, height: verticalLength),
            cursor: resizeCursor(for: .left)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - edgeWidth, y: cornerSize, width: edgeWidth, height: verticalLength),
            cursor: resizeCursor(for: .right)
        )

        addCursorRect(
            NSRect(x: bounds.minX, y: bounds.maxY - cornerSize, width: cornerSize, height: cornerSize),
            cursor: resizeCursor(for: .topLeft)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - cornerSize, y: bounds.maxY - cornerSize, width: cornerSize, height: cornerSize),
            cursor: resizeCursor(for: .topRight)
        )
        addCursorRect(
            NSRect(x: bounds.minX, y: bounds.minY, width: cornerSize, height: cornerSize),
            cursor: resizeCursor(for: .bottomLeft)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - cornerSize, y: bounds.minY, width: cornerSize, height: cornerSize),
            cursor: resizeCursor(for: .bottomRight)
        )
    }

    private enum ResizePosition {
        case top, left, bottom, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func resizePosition(at point: NSPoint) -> ResizePosition? {
        guard bounds.contains(point),
              bounds.width > resizeCornerSize * 2,
              bounds.height > resizeCornerSize * 2 else { return nil }

        let nearLeft = point.x < bounds.minX + resizeCornerSize
        let nearRight = point.x >= bounds.maxX - resizeCornerSize
        let nearBottom = point.y < bounds.minY + resizeCornerSize
        let nearTop = point.y >= bounds.maxY - resizeCornerSize
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if point.x < bounds.minX + resizeEdgeWidth { return .left }
        if point.x >= bounds.maxX - resizeEdgeWidth { return .right }
        if point.y < bounds.minY + resizeEdgeWidth { return .bottom }
        if point.y >= bounds.maxY - resizeEdgeWidth { return .top }
        return nil
    }

    private func resizeCursor(for position: ResizePosition) -> NSCursor {
        if #available(macOS 15.0, *) {
            let framePosition: NSCursor.FrameResizePosition = switch position {
            case .top: .top
            case .left: .left
            case .bottom: .bottom
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return NSCursor.frameResize(position: framePosition, directions: .all)
        }

        switch position {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return Self.diagonalDownCursor
        case .topRight, .bottomLeft:
            return Self.diagonalUpCursor
        }
    }

    private static func diagonalCursor(symbol: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)) else {
            return .crosshair
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    private func updateCursor(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if isPointerInside, toolMenu.frame.contains(point) {
            NSCursor.pointingHand.set()
            return
        }
        guard !isPinned else {
            NSCursor.arrow.set()
            return
        }
        let position = resizePosition(at: point)
        (position.map { resizeCursor(for: $0) } ?? NSCursor.arrow).set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            // PiP panels do not become key windows. cursorUpdate cannot be used
            // with activeAlways, so mouseMoved also updates non-active panels.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        window?.invalidateCursorRects(for: self)
        updateCursor(with: event)
        showTools()
    }

    override func mouseMoved(with event: NSEvent) {
        showTools()
        updateCursor(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !toolbarPreviewOnly else { return }
        pendingHide?.cancel()
        // Moving across child views can deliver an exit before their enter.
        // Resolve that transition using the pointer position in the whole PiP.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if self.bounds.contains(point) {
                self.showTools()
            } else {
                self.hideTools()
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func hideTools() {
        guard toolsVisible, !seekSlider.isTrackingPosition else { return }
        toolsVisible = false
        isPointerInside = false
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
        animateTools(visible: false)
    }

    private func configureToolButton(_ button: PiPToolButton, symbol: String, description: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = PiPToolbarStyle.icon(symbol)
        button.setAccessibilityLabel(description)
        // Keep the symbol at its intrinsic size inside the larger hit target.
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .white
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.masksToBounds = true
    }

    private func showTools() {
        pendingHide?.cancel()
        pendingHide = nil
        guard !toolsVisible else { return }
        toolsVisible = true
        isPointerInside = true
        animateTools(visible: true)
        window?.invalidateCursorRects(for: self)
    }

    private func animateTools(visible: Bool) {
        updateHeaderVisibility()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : (visible ? 0.14 : 0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            controlsOverlay.animator().alphaValue = visible ? 1 : 0
            mediaMenu.animator().alphaValue = visible && hasVideoControls ? 1 : 0
            buttonRow.animator().alphaValue = visible && hasVideoControls ? 1 : 0
        }
    }

    private func updatePinAppearance() {
        let tint = isPinned ? tabTheme.pinnedIconColor : tabTheme.tabForeground
        pinButton.contentTintColor = tint
        let background = isPinned ? tabTheme.pinnedBackground : .clear
        pinButton.layer?.backgroundColor = (pinHovered
            ? background.blended(withFraction: 0.14, of: tint) ?? background
            : background).cgColor
        pinButton.needsDisplay = true
    }

    @objc private func togglePin() {
        isPinned.toggle()
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton.image = PiPToolbarStyle.icon(symbol, size: 12)
        pinButton.toolTip = isPinned ? L10n.text("位置の固定を解除", "Unlock Position") : L10n.text("位置を固定", "Lock Position")
        pinButton.setAccessibilityLabel(pinButton.toolTip)
        updatePinAppearance()
        onPinChanged(isPinned)
        showTools()
    }
}

// Accept both trackpad horizontal swipes and an ordinary mouse wheel.
private final class PiPTabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        let maximum = max(0, documentView.bounds.width - contentView.bounds.width)
        let x = min(maximum, max(0, contentView.bounds.minX - delta * scale))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

// Reserve the close target even when hidden so hovering does not shift the title.
private final class PiPTabButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: NSRect(x: rect.minX + 5, y: rect.minY,
                                         width: max(0, rect.width - 28), height: rect.height))
    }
}

// Draw against the button bounds, avoiding NSButtonCell's bezel/image offsets.
private final class PiPTabCloseCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let center = NSPoint(x: controlView.bounds.midX, y: controlView.bounds.midY)
        let radius: CGFloat = 3
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: center.x - radius, y: center.y - radius))
        path.line(to: NSPoint(x: center.x + radius, y: center.y + radius))
        path.move(to: NSPoint(x: center.x - radius, y: center.y + radius))
        path.line(to: NSPoint(x: center.x + radius, y: center.y - radius))
        ((controlView as? NSButton)?.contentTintColor ?? .white).setStroke()
        path.stroke()
    }
}

private final class PiPTabButton: PiPToolButton, NSDraggingSource {
    var onCloseTab: (() -> Void)?
    var dragIdentifier: String?
    var onDetach: ((String, NSPoint) -> Bool)?
    private let tabCloseButton = PiPToolButton(frame: .zero)
    private var theme = PiPTheme.saved
    private var selected = false
    private var hovered = false
    private var closeHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = PiPTabButtonCell(textCell: "")
        tabCloseButton.cell = PiPTabCloseCell(textCell: "")
        tabCloseButton.isBordered = false
        tabCloseButton.image = PiPToolbarStyle.icon("xmark", size: 9)
        tabCloseButton.imagePosition = .imageOnly
        tabCloseButton.contentTintColor = .white
        tabCloseButton.toolTip = L10n.text("このタブを閉じる", "Close This Tab")
        tabCloseButton.setAccessibilityLabel(L10n.text("このタブを閉じる", "Close This Tab"))
        tabCloseButton.target = self
        tabCloseButton.action = #selector(closeTab)
        tabCloseButton.wantsLayer = true
        tabCloseButton.layer?.masksToBounds = true
        tabCloseButton.isHidden = true
        tabCloseButton.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.closeHovered = hovering
            self.updateColors()
        }
        addSubview(tabCloseButton)
    }

    func applyTheme(_ theme: PiPTheme, selected: Bool) {
        self.theme = theme
        self.selected = selected
        wantsLayer = true
        updateColors()
    }

    private func updateColors() {
        let foreground = selected ? theme.selectedTabForeground : theme.tabForeground
        contentTintColor = foreground
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let styledTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: foreground,
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .paragraphStyle: paragraph
        ])
        attributedTitle = styledTitle
        attributedAlternateTitle = styledTitle
        layer?.backgroundColor = theme.tabBackground(selected: selected, hovered: hovered).cgColor
        tabCloseButton.contentTintColor = foreground
        tabCloseButton.layer?.backgroundColor = closeHovered
            ? foreground.withAlphaComponent(0.20).cgColor : NSColor.clear.cgColor
        tabCloseButton.needsDisplay = true
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        guard let window, let dragIdentifier else {
            super.mouseDown(with: event)
            return
        }
        let start = event.locationInWindow
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp {
                performClick(nil)
                return
            }
            let distance = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            guard distance >= 4 else { continue }

            let item = NSPasteboardItem()
            item.setString(dragIdentifier, forType: .pipTab)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            draw(bounds)
            image.unlockFocus()
            draggingItem.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [draggingItem], event: next, source: self)
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard operation.isEmpty, let dragIdentifier else { return }
        _ = onDetach?(dragIdentifier, screenPoint)
    }

    override func layout() {
        super.layout()
        let diameter = min(20, bounds.width, bounds.height)
        tabCloseButton.frame = NSRect(x: max(0, bounds.width - diameter - 2),
                                     y: (bounds.height - diameter) / 2,
                                     width: diameter, height: diameter)
        tabCloseButton.layer?.cornerRadius = diameter / 2
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateColors()
        tabCloseButton.isHidden = false
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !hovered { hovered = true; updateColors() }
        tabCloseButton.isHidden = false
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        // Moving onto the child close button is still hovering this tab.
        guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        hovered = false
        closeHovered = false
        updateColors()
        tabCloseButton.isHidden = true
        super.mouseExited(with: event)
    }

    @objc private func closeTab() { onCloseTab?() }
}

private class PiPToolButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
        onHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        // Cursor rects are ignored by inactive non-activating panels on some
        // macOS versions, so apply it directly while the pointer is moving.
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?(false)
        super.mouseExited(with: event)
    }
}

private final class ClosureTarget: NSObject {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() { action() }
}

// Screen captureやChrome接続を開始せず、実際のツールバーだけを表示します。
// Live Previewではピン切り替えとボタンのホバーも確認できます。
private struct PiPToolbarPreview: NSViewRepresentable {
    var initiallyPinned = false

    func makeNSView(context: Context) -> PiPContainerView {
        let view = PiPContainerView(onClose: {}, onPinChanged: { _ in })
        view.configureToolbarPreview(pinned: initiallyPinned)
        return view
    }

    func updateNSView(_ nsView: PiPContainerView, context: Context) {}
}

#Preview("PiPツールバー・白背景") {
    PiPToolbarPreview()
        .frame(width: PiPToolbarStyle.width + 16, height: PiPToolbarStyle.height + 16)
        .padding(24)
        .background(Color.white)
}

#Preview("PiPツールバー・暗い背景") {
    PiPToolbarPreview()
        .frame(width: PiPToolbarStyle.width + 16, height: PiPToolbarStyle.height + 16)
        .padding(24)
        .background(Color(white: 0.12))
}

#Preview("PiPツールバー・固定中") {
    PiPToolbarPreview(initiallyPinned: true)
        .frame(width: PiPToolbarStyle.width + 16, height: PiPToolbarStyle.height + 16)
        .padding(24)
        .background(Color.white)
}
