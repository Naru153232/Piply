import AppKit
import AVFoundation
import ScreenCaptureKit
import WebKit

final class CapturePreviewView: NSView {
    private let cropLayer = CALayer()
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var sourceSize = CGSize(width: 1, height: 1)
    private var cropRect: CGRect?
    private var lastReportedSize: CGSize?
    var onSourceSizeChanged: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        cropLayer.masksToBounds = true
        layer?.addSublayer(cropLayer)
        cropLayer.addSublayer(displayLayer)
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor

    }

    required init?(coder: NSCoder) { nil }

    func configure(sourceSize: CGSize, cropRect: CGRect?) {
        self.sourceSize = sourceSize
        self.cropRect = cropRect
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    override func setFrameSize(_ newSize: NSSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        super.setFrameSize(newSize)
        // Live resizing can happen between video frames. Update the backing
        // layers immediately instead of waiting for the next layout pass.
        updateLayerFrames()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        super.setBoundsSize(newSize)
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let crop = cropRect ?? CGRect(origin: .zero, size: sourceSize)
        guard crop.width > 0, crop.height > 0 else {
            cropLayer.frame = bounds
            displayLayer.frame = cropLayer.bounds
            return
        }
        // Fit the complete source inside the PiP instead of filling the PiP by
        // cutting off an edge when the two aspect ratios differ slightly.
        // The intermediate layer still clips intentional crops (for example,
        // a Chrome viewport) without exposing pixels outside the crop.
        let scale = min(bounds.width / crop.width, bounds.height / crop.height)
        let bottomInset = max(sourceSize.height - crop.maxY, 0)
        cropLayer.frame = CGRect(
            x: (bounds.width - crop.width * scale) / 2,
            y: (bounds.height - crop.height * scale) / 2,
            width: crop.width * scale,
            height: crop.height * scale
        )
        displayLayer.frame = CGRect(
            x: -crop.minX * scale,
            y: -bottomInset * scale,
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    func display(_ sampleBuffer: CMSampleBuffer) {
        // ScreenCaptureKit's surface can stay fixed while its window changes size.
        // Crop the padding described by frame metadata, never by pixel color.
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let metadata = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
           let rect = (metadata[.contentRect] as? CGRect) ??
                (metadata[.contentRect] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
           let scaleFactor = Self.number(metadata[.scaleFactor]) {
            let surface = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            // contentRect is expressed in source points. When ScreenCaptureKit
            // scales a resized window into the fixed stream surface, contentScale
            // is the additional transform needed to locate the actual pixels.
            // Ignoring it leaves the stream's black padding visible.
            let contentScale = Self.number(metadata[.contentScale]) ?? 1
            let pixelScale = scaleFactor * contentScale
            let content = CGRect(x: rect.minX * pixelScale, y: rect.minY * pixelScale,
                                 width: rect.width * pixelScale, height: rect.height * pixelScale)
                .integral
                .intersection(CGRect(origin: .zero, size: surface))
            if !content.isEmpty, !content.isNull {
                configure(sourceSize: surface, cropRect: content)
                reportSourceSize(content.size)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.isHidden = false
        layoutSubtreeIfNeeded()
        updateLayerFrames()
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
        CATransaction.commit()
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        return nil
    }

    private func reportSourceSize(_ size: CGSize) {
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        // Re-fitting the panel on every frame fights the user's live resize.
        onSourceSizeChanged?(size)
    }
}

// Receive-only WebRTC view. The only native bridge messages are SDP, size,
// readiness and errors; decoded video stays inside WebKit's media pipeline.
struct PiPVideoState {
    let paused: Bool
    let muted: Bool
    let currentTime: Double
    let duration: Double?
    let seekStart: Double?
    let seekEnd: Double?
}

final class ChromeStreamView: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {
    var onVideoState: ((PiPVideoState) -> Void)?
    var onVideoUnavailable: (() -> Void)?
    var onVideoResuming: (() -> Void)?
    var onAnswer: ((String) -> Void)?
    var onSize: ((CGSize) -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    private var offer: String?
    private var viewport: CGSize = .zero
    private var pageReady = false
    private var stopped = false
    private var presentationActive = true

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        configuration.userContentController.add(self, name: "pip")
        loadHTMLString(Self.receiverHTML, baseURL: URL(string: "https://piply.invalid"))
    }

    required init?(coder: NSCoder) { nil }

    // The video surface must not swallow the panel's drag/hover events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func receive(offer: String, viewport: CGSize) {
        self.offer = offer
        self.viewport = viewport
        startIfReady()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        startIfReady()
    }

    private func startIfReady() {
        guard pageReady, !stopped, let offer else { return }
        self.offer = nil
        callAsyncJavaScript("setPresentationActive(active); await start(sdp, width, height)", arguments: [
            "sdp": offer, "width": viewport.width, "height": viewport.height, "active": presentationActive
        ], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.onError?(error.localizedDescription) }
        }
    }

    func stop() {
        stopped = true
        evaluateJavaScript("stop()", completionHandler: nil)
        configuration.userContentController.removeScriptMessageHandler(forName: "pip")
        onAnswer = nil; onSize = nil; onReady = nil; onError = nil
        onVideoState = nil; onVideoUnavailable = nil; onVideoResuming = nil
        stopLoading()
    }

    func controlVideo(_ command: String) {
        callAsyncJavaScript("controlVideo(command)", arguments: ["command": command], in: nil, in: .page, completionHandler: nil)
    }

    func seekVideo(to time: Double) {
        guard time.isFinite else { return }
        callAsyncJavaScript("controlVideo('seek', time)", arguments: ["time": time], in: nil, in: .page, completionHandler: nil)
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        guard pageReady else { return }
        callAsyncJavaScript("setPresentationActive(active)", arguments: ["active": active], in: nil, in: .page, completionHandler: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !stopped { onError?(L10n.text("映像の再生プロセスが終了しました。タブを選び直してください。", "The video playback process ended. Select the tab again.")) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "videoResuming": onVideoResuming?()
        case "videoUnavailable": onVideoUnavailable?()
        case "videoState":
            if let paused = body["paused"] as? Bool, let muted = body["muted"] as? Bool {
                func number(_ key: String) -> Double? {
                    guard let value = body[key] as? Double, value.isFinite, value >= 0 else { return nil }
                    return value
                }
                onVideoState?(PiPVideoState(paused: paused, muted: muted,
                    currentTime: number("currentTime") ?? 0, duration: number("duration"),
                    seekStart: number("seekStart"), seekEnd: number("seekEnd")))
            }
        case "answer": if let sdp = body["sdp"] as? String { onAnswer?(sdp) }
        case "size":
            if let width = body["width"] as? Double, let height = body["height"] as? Double,
               width.isFinite, height.isFinite, width > 0, height > 0 {
                onSize?(CGSize(width: width, height: height))
            }
        case "ready": onReady?()
        case "error": onError?(body["error"] as? String ?? L10n.text("映像の再生に失敗しました。", "Video playback failed."))
        default: break
        }
    }

    private static let receiverHTML = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
    video{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);object-fit:fill;pointer-events:none}</style>
    </head><body><video id="video" autoplay muted playsinline></video><script>
    const video = document.getElementById('video');
    let peer, channel, viewport, ready = false, closed = false, lastSize = '', disconnectTimer;
    let displayTimer, displayHeartbeat, lastDisplay = '';
    let presentationActive = true;
    let mediaAvailable = true;
    function setPresentationActive(active) {
      presentationActive = active;
      if (channel?.readyState === 'open') channel.send(JSON.stringify({action:'presentation', active}));
    }
    const post = (action, extra = {}) => window.webkit.messageHandlers.pip.postMessage({action, ...extra});
    function sendDisplaySize() {
      if (closed || channel?.readyState !== 'open' || innerWidth <= 0 || innerHeight <= 0) return;
      const width = Math.round(innerWidth * devicePixelRatio);
      const height = Math.round(innerHeight * devicePixelRatio);
      const key = width + ':' + height;
      if (key === lastDisplay) return;
      lastDisplay = key;
      channel.send(JSON.stringify({action:'displaySize', width, height}));
    }
    function controlVideo(command, time) {
      if (channel?.readyState === 'open') channel.send(JSON.stringify({action:'videoControl', command, time}));
    }
    function fit() {
      if (!video.videoWidth || !video.videoHeight) return;
      const sourceWidth = viewport?.sourceWidth || viewport?.width || video.videoWidth;
      const sourceHeight = viewport?.sourceHeight || viewport?.height || video.videoHeight;
      const sourceScale = Math.min(video.videoWidth / sourceWidth, video.videoHeight / sourceHeight);
      const sourceX = (video.videoWidth - sourceWidth * sourceScale) / 2;
      const sourceY = (video.videoHeight - sourceHeight * sourceScale) / 2;
      const crop = viewport?.crop || {x:0, y:0, width:sourceWidth, height:sourceHeight};
      const x = sourceX + crop.x * sourceScale, y = sourceY + crop.y * sourceScale;
      const w = crop.width * sourceScale, h = crop.height * sourceScale;
      // Keep the entire captured viewport visible. Any difference in aspect
      // ratio becomes letterboxing instead of cropping an edge of the app.
      const scale = Math.min(innerWidth / w, innerHeight / h);
      video.style.transform = 'none';
      video.style.left = ((innerWidth - w * scale) / 2 - x * scale) + 'px';
      video.style.top = ((innerHeight - h * scale) / 2 - y * scale) + 'px';
      video.style.width = video.videoWidth * scale + 'px';
      video.style.height = video.videoHeight * scale + 'px';
      const size = crop.width + ':' + crop.height;
      if (lastSize !== size) { lastSize = size; post('size', {width:crop.width, height:crop.height}); }
    }
    function rendered() {
      if (closed || ready || !mediaAvailable) return;
      ready = true; fit(); post('ready');
      if (channel?.readyState === 'open') channel.send(JSON.stringify({action:'ready'}));
    }
    video.addEventListener('resize', fit);
    window.addEventListener('resize', () => {
      fit(); clearTimeout(displayTimer);
      displayTimer = setTimeout(sendDisplaySize, 120);
    });
    video.addEventListener('playing', () => {
      fit();
      if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(rendered);
      else rendered();
    });
    async function start(sdp, width, height) {
      try {
        viewport = {width, height};
        peer = new RTCPeerConnection({iceServers:[]});
        peer.ontrack = event => {
          video.srcObject = new MediaStream([event.track]);
          video.play().catch(error => post('error', {error:error.message}));
        };
        peer.ondatachannel = event => {
          channel = event.channel;
          channel.onopen = () => {
            setPresentationActive(presentationActive);
            sendDisplaySize();
            if (ready) channel.send(JSON.stringify({action:'ready'}));
          };
          channel.onmessage = event => {
            try {
              const data = JSON.parse(event.data);
              if (data.action === 'videoAvailability') {
                mediaAvailable = data.available === true;
                if (!mediaAvailable) { ready = false; post('videoUnavailable'); }
                else {
                  post('videoResuming');
                  if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(rendered);
                  else if (video.readyState >= 2) rendered();
                }
              }
              if (data.action === 'viewport' && data.width > 0 && data.height > 0) {
                viewport = data; fit();
                if (data.video) post('videoState', data.video);
                sendDisplaySize();
              }
            } catch (_) {}
          };
        };
        displayHeartbeat = setInterval(sendDisplaySize, 3000);
        peer.onconnectionstatechange = () => {
          clearTimeout(disconnectTimer);
          if (closed) return;
          if (peer.connectionState === 'failed') post('error', {error:'タブ映像に接続できませんでした。'});
          if (peer.connectionState === 'disconnected') disconnectTimer = setTimeout(() => {
            if (!closed) post('error', {error:'タブ映像の接続が切れました。'});
          }, 5000);
        };
        await peer.setRemoteDescription({type:'offer', sdp});
        await peer.setLocalDescription(await peer.createAnswer());
        if (peer.iceGatheringState !== 'complete') await new Promise((resolve, reject) => {
          let settleTimer;
          const timer = setTimeout(() => finish(new Error('映像接続がタイムアウトしました。')), 8000);
          function candidate(event) {
            if (event.candidate && !settleTimer) settleTimer = setTimeout(() => finish(), 250);
          }
          function changed() { if (peer.iceGatheringState === 'complete') finish(); }
          function finish(error) {
            clearTimeout(timer); clearTimeout(settleTimer);
            peer.removeEventListener('icecandidate', candidate);
            peer.removeEventListener('icegatheringstatechange', changed);
            error ? reject(error) : resolve();
          }
          peer.addEventListener('icegatheringstatechange', changed);
          peer.addEventListener('icecandidate', candidate); changed();
        });
        if (!closed) post('answer', {sdp:peer.localDescription.sdp});
      } catch (error) { if (!closed) post('error', {error:error.message}); }
    }
    function stop() {
      closed = true; clearTimeout(disconnectTimer); clearTimeout(displayTimer);
      clearInterval(displayHeartbeat); peer?.close(); video.srcObject = null;
    }
    </script></body></html>
    """#
}

