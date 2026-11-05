import AppKit
import ScreenCaptureKit

private final class UnconstrainedPiPPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class PiPPanelController: NSWindowController, NSWindowDelegate {
    private let source: CaptureSource
    private let selectionKey: String
    private let container: PiPContainerView
    private var session: ScreenStreamSession?
    private var captureTask: Task<Void, Never>?
    private var softShadow: PiPSoftShadow?
    private let onClose: (String) -> Void

    init(
        source: CaptureSource,
        selectionKey: String,
        preferredTopLeft: NSPoint? = nil,
        preferredContentWidth: CGFloat? = nil,
        onClose: @escaping (String) -> Void
    ) {
        self.source = source
        self.selectionKey = selectionKey
        self.onClose = onClose
        var closeAction: (() -> Void)?
        var pinAction: ((Bool) -> Void)?
        self.container = PiPContainerView(
            onClose: { closeAction?() },
            onPinChanged: { pinAction?($0) }
        )
        let captureSize = source.captureSize
        container.sourceSize = captureSize
        let aspect = max(captureSize.width, 1) / max(captureSize.height, 1)
        let width = max(preferredContentWidth ?? 480, PiPGeometry.minimumWidth)
        let panel = UnconstrainedPiPPanel(
            contentRect: NSRect(x: 80, y: 80, width: width, height: width / aspect),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = captureSize
        panel.contentMinSize = NSSize(width: PiPGeometry.minimumWidth, height: PiPGeometry.minimumWidth / aspect)
        panel.contentView = container
        container.preview.configure(sourceSize: source.window.frame.size, cropRect: source.cropRect)
        PiPGeometry.fit(panel, to: captureSize, preferredWidth: width)
        if let preferredTopLeft {
            panel.setFrameTopLeftPoint(preferredTopLeft)
        } else {
            PiPGeometry.placeAtBottomRight(panel)
        }
        super.init(window: panel)
        softShadow = PiPSoftShadow(attachedTo: panel)
        closeAction = { [weak self] in self?.close() }
        pinAction = { [weak panel] pinned in
            guard let panel else { return }
            panel.isMovableByWindowBackground = !pinned
            if pinned { panel.styleMask.remove(.resizable) }
            else { panel.styleMask.insert(.resizable) }
        }
        container.preview.onSourceSizeChanged = { [weak panel] size in
            if let panel { PiPGeometry.fit(panel, to: size) }
        }
        panel.delegate = self
        startCapture()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PiPGeometry.constrainResize(sender, proposed: frameSize)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        container.beginResize()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, window.inLiveResize else { return }
        PiPGeometry.keepInsideVisibleFrame(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        container.endResize()
        if let window { PiPGeometry.fit(window, to: container.sourceSize) }
    }

    private func startCapture() {
        setPresentationActive(true)
    }

    func setPresentationActive(_ active: Bool) {
        let previous = captureTask
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if active {
                guard self.session == nil else { return }
                let stream = ScreenStreamSession(window: self.source.window, preview: self.container.preview)
                self.session = stream
                try? await stream.start()
            } else {
                await self.session?.stop()
                self.session = nil
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the stream alive until the serialized stop has completed.
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            await self.session?.stop()
            self.session = nil
        }
        onClose(selectionKey)
    }
}

@MainActor
final class ChromeTabPiPPanelController: NSWindowController, NSWindowDelegate {
    let tabID: Int
    private(set) var requestID: String
    private var streamView = ChromeStreamView()
    private var streamStarted = false
    private var announcedReady = false
    private(set) var currentStreamID: String?
    private(set) var retainsVideoTab = false
    private var wantsPresentation = true
    private var hasReceivedFrame = false
    private var connectionTimeout: Task<Void, Never>?
    var onStreamReady: (() -> Void)?
    var onStreamError: ((String) -> Void)?
    private let selectionKey: String
    private let container: PiPContainerView
    private let onClose: (String) -> Void
    private var softShadow: PiPSoftShadow?

    init(
        tabID: Int,
        requestID: String,
        title: String,
        contentSize: CGSize,
        selectionKey: String,
        preferredTopLeft: NSPoint? = nil,
        preferredContentWidth: CGFloat? = nil,
        onClose: @escaping (String) -> Void
    ) {
        self.tabID = tabID
        self.requestID = requestID
        self.selectionKey = selectionKey
        self.onClose = onClose
        var closeAction: (() -> Void)?
        var pinAction: ((Bool) -> Void)?
        self.container = PiPContainerView(
            onClose: { closeAction?() },
            onPinChanged: { pinAction?($0) }
        )

        let safeSize = CGSize(width: max(contentSize.width, 1), height: max(contentSize.height, 1))
        container.sourceSize = safeSize
        let aspect = safeSize.width / safeSize.height
        let width = max(preferredContentWidth ?? 480, PiPGeometry.minimumWidth)
        let panel = UnconstrainedPiPPanel(
            contentRect: NSRect(x: 80, y: 80, width: width, height: width / aspect),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = safeSize
        panel.contentMinSize = NSSize(width: PiPGeometry.minimumWidth, height: PiPGeometry.minimumWidth / aspect)
        panel.contentView = container
        container.preview.configure(sourceSize: safeSize, cropRect: nil)
        PiPGeometry.fit(panel, to: safeSize, preferredWidth: width)
        if let preferredTopLeft { panel.setFrameTopLeftPoint(preferredTopLeft) }
        else { PiPGeometry.placeAtBottomRight(panel) }

        super.init(window: panel)
        softShadow = PiPSoftShadow(attachedTo: panel)
        closeAction = { [weak self] in self?.close() }
        pinAction = { [weak panel] pinned in
            guard let panel else { return }
            panel.isMovableByWindowBackground = !pinned
            if pinned { panel.styleMask.remove(.resizable) }
            else { panel.styleMask.insert(.resizable) }
        }
        container.preview.onSourceSizeChanged = { [weak panel] size in
            if let panel { PiPGeometry.fit(panel, to: size) }
        }
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func replaceRequest(_ newRequestID: String) {
        if requestID != newRequestID {
            ChromeCommandStore.requestStopTabCapture(tabID: tabID, requestID: requestID)
            requestID = newRequestID
        }
    }

    func setVideoWaiting() {
        connectionTimeout?.cancel()
        container.setVideoWaiting(true)
    }

    func reconnectVideo() {
        guard retainsVideoTab else { return }
        setVideoWaiting()
        ChromeCommandStore.requestVideoReconnect(tabID: tabID, requestID: requestID, streamID: currentStreamID)
    }

    func startStream(offer: String, viewport: CGSize, streamID: String? = nil, videoElement: Bool = false) {
        connectionTimeout?.cancel()
        currentStreamID = streamID
        retainsVideoTab = videoElement
        if streamStarted {
            streamView.stop()
            streamView = ChromeStreamView()
        }
        streamStarted = true
        hasReceivedFrame = false
        if videoElement { setVideoWaiting() }
        streamView.onVideoUnavailable = { [weak self] in self?.setVideoWaiting() }
        streamView.onVideoResuming = { [weak self] in self?.container.resumeVideoSurface() }
        container.installStreamView(streamView)
        container.onVideoControl = { [weak self] command in self?.streamView.controlVideo(command) }
        container.onVideoSeek = { [weak self] time in self?.streamView.seekVideo(to: time) }
        streamView.onVideoState = { [weak self] state in
            self?.container.updateVideoControls(state)
        }
        streamView.onAnswer = { [weak self] sdp in
            guard let self else { return }
            do { try ChromeCommandStore.requestStreamAnswer(tabID: self.tabID, requestID: self.requestID, sdp: sdp, streamID: streamID) }
            catch {
                if self.retainsVideoTab { self.reconnectVideo() }
                else { self.onStreamError?(error.localizedDescription) }
            }
        }
        streamView.onSize = { [weak self] size in
            if let panel = self?.window { PiPGeometry.fit(panel, to: size) }
        }
        streamView.onReady = { [weak self] in
            guard let self else { return }
            self.hasReceivedFrame = true
            self.container.setVideoWaiting(false)
            self.streamView.setPresentationActive(self.wantsPresentation)
            self.connectionTimeout?.cancel()
            if !self.announcedReady {
                self.announcedReady = true
                self.onStreamReady?()
            }
        }
        streamView.onError = { [weak self] error in
            guard let self else { return }
            if self.retainsVideoTab {
                self.setVideoWaiting()
                ChromeCommandStore.requestVideoReconnect(tabID: self.tabID, requestID: self.requestID, streamID: self.currentStreamID)
            } else { self.onStreamError?(error) }
        }
        connectionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self else { return }
            if self.retainsVideoTab {
                self.setVideoWaiting()
                ChromeCommandStore.requestVideoReconnect(tabID: self.tabID, requestID: self.requestID, streamID: self.currentStreamID)
            } else {
                self.onStreamError?(L10n.text("映像の接続がタイムアウトしました。Chrome拡張を再読み込みしてタブを選び直してください。", "The video connection timed out. Reload the Chrome extension and select the tab again."))
            }
        }
        streamView.receive(offer: offer, viewport: viewport)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PiPGeometry.constrainResize(sender, proposed: frameSize)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        container.beginResize()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, window.inLiveResize else { return }
        PiPGeometry.keepInsideVisibleFrame(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        container.endResize()
        if let window { PiPGeometry.fit(window, to: container.sourceSize) }
    }

    func setPresentationActive(_ active: Bool) {
        wantsPresentation = active
        // Deliver the first frame before suspending a newly added tab so
        // switching quickly does not incorrectly trip the startup timeout.
        if active || hasReceivedFrame { streamView.setPresentationActive(active) }
    }

    func windowWillClose(_ notification: Notification) {
        connectionTimeout?.cancel()
        streamView.stop()
        ChromeCommandStore.requestStopTabCapture(tabID: tabID, requestID: requestID)
        onClose(selectionKey)
    }
}

@MainActor
private final class PiPSoftShadow {
    private weak var owner: NSWindow?
    private let shadowWindow: NSPanel
    private let shadowLayer = CALayer()
    private var observers: [NSObjectProtocol] = []
    private let padding: CGFloat = 24

    init(attachedTo owner: NSWindow) {
        self.owner = owner
        shadowWindow = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        shadowWindow.isOpaque = false
        shadowWindow.backgroundColor = .clear
        shadowWindow.hasShadow = false
        shadowWindow.ignoresMouseEvents = true
        shadowWindow.hidesOnDeactivate = false
        shadowWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        shadowWindow.sharingType = .none

        let content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        // The explicit shadowPath casts the shadow without an opaque backing
        // rectangle that could peek out while the owner shrinks.
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.cornerRadius = 0
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.14
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        content.layer?.addSublayer(shadowLayer)
        shadowWindow.contentView = content

        syncFrame()
        owner.addChildWindow(shadowWindow, ordered: .below)
        shadowWindow.orderFront(nil)

        let center = NotificationCenter.default
        observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFrame() }
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func syncFrame() {
        guard let owner else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let frame = owner.frame.insetBy(dx: -padding, dy: -padding)
        shadowWindow.setFrame(frame, display: true)
        shadowWindow.level = owner.level
        shadowLayer.frame = CGRect(
            x: padding,
            y: padding,
            width: owner.frame.width,
            height: owner.frame.height
        )
        shadowLayer.shadowPath = CGPath(
            roundedRect: shadowLayer.bounds,
            cornerWidth: shadowLayer.cornerRadius,
            cornerHeight: shadowLayer.cornerRadius,
            transform: nil
        )
    }
}

// Both capture routes resize the borderless content area, not a title-bar frame.
// Keep the user's top-left position and width unless the new aspect is too tall.
@MainActor
enum PiPGeometry {
    static let minimumWidth: CGFloat = 100

    /// During native live resize, AppKit stops producing useful growth once
    /// the dragged edge reaches the menu bar, Dock, or a display boundary.
    /// Slide the panel back into the usable frame after each size update so
    /// the pointer can keep changing its size instead of getting stuck.
    static func keepInsideVisibleFrame(_ panel: NSWindow) {
        guard var screenFrame = panel.screen?.visibleFrame else { return }
        let frame = panel.frame

        // A PiP larger than a display cannot be fully contained. Keep a tiny
        // inset and let the aspect-ratio constraint choose the limiting axis.
        screenFrame = screenFrame.insetBy(dx: 2, dy: 2)
        let maxX = max(screenFrame.minX, screenFrame.maxX - frame.width)
        let maxY = max(screenFrame.minY, screenFrame.maxY - frame.height)
        let origin = NSPoint(
            x: min(max(frame.origin.x, screenFrame.minX), maxX),
            y: min(max(frame.origin.y, screenFrame.minY), maxY)
        )
        guard abs(origin.x - frame.origin.x) > 0.5 || abs(origin.y - frame.origin.y) > 0.5 else { return }
        panel.setFrameOrigin(origin)
    }

    static func placeAtBottomRight(_ panel: NSWindow, margin: CGFloat = 24) {
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.minY + margin
        ))
    }

    static func fittedSize(source: CGSize, preferredWidth: CGFloat, maximum: CGSize? = nil) -> CGSize? {
        guard source.width.isFinite, source.height.isFinite,
              preferredWidth.isFinite,
              source.width > 0, source.height > 0 else { return nil }
        let aspect = source.width / source.height
        var width = max(preferredWidth, 1)
        if let maximum {
            guard maximum.width.isFinite, maximum.height.isFinite else { return nil }
            width = min(width, max(maximum.width, 1), max(maximum.height, 1) * aspect)
        }
        return CGSize(width: width, height: width / aspect)
    }

    static func fit(_ panel: NSWindow, to source: CGSize, preferredWidth: CGFloat? = nil) {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return }
        let container = panel.contentView as? PiPContainerView
        container?.sourceSize = source
        // Metadata may arrive during a drag. Apply it once the drag ends,
        // never reposition the window between AppKit's resize updates.
        guard !panel.inLiveResize else { return }
        let barHeight = container?.headerHeight ?? 0
        let current = panel.contentView?.bounds.size ?? panel.frame.size
        let desiredWidth = preferredWidth ?? current.width
        guard var size = fittedSize(source: source, preferredWidth: desiredWidth) else { return }
        size.height += barHeight
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        // Restore native aspect-constrained resizing when no header is shown.
        if barHeight == 0 { panel.contentAspectRatio = source }
        else { panel.contentResizeIncrements = NSSize(width: 1, height: 1) }
        let minimumWidth = min(Self.minimumWidth, size.width)
        panel.contentMinSize = NSSize(width: minimumWidth, height: minimumWidth * source.height / source.width + barHeight)
        if abs(current.width - size.width) > 0.01 || abs(current.height - size.height) > 0.01 {
            panel.setContentSize(size)
            panel.setFrameTopLeftPoint(topLeft)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    static func constrainResize(_ panel: NSWindow, proposed: NSSize) -> NSSize {
        guard proposed.width.isFinite, proposed.height.isFinite else { return panel.frame.size }
        // AppKit handles single-tab resizing. Only a fixed-height header needs
        // an adjustment to the proposed size; never rewrite the drag origin.
        guard panel.inLiveResize,
              let view = panel.contentView as? PiPContainerView, view.headerHeight > 0,
              view.sourceSize.width > 0, view.sourceSize.height > 0 else { return proposed }
        return view.constrainedResize(proposed)
    }
}
