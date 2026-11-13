import AVFoundation
import ScreenCaptureKit

final class ScreenStreamSession: NSObject, SCStreamOutput {
    private let window: SCWindow
    private weak var preview: CapturePreviewView?
    private let outputQueue = DispatchQueue(label: "com.naru.piply.video", qos: .userInitiated)
    private var stream: SCStream?

    init(window: SCWindow, preview: CapturePreviewView) {
        self.window = window
        self.preview = preview
    }

    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let sourceWidth = max(filter.contentRect.width * scale, 1)
        let sourceHeight = max(filter.contentRect.height * scale, 1)
        // A Retina Chrome window can exceed 5K even though the PiP is only a
        // fraction of that size. Capturing every source pixel makes Chrome's
        // compositor and the app copy far more data than the preview can show.
        let outputScale = min(1, 1920 / sourceWidth, 1080 / sourceHeight)
        configuration.width = max(Int((sourceWidth * outputScale).rounded()), 320)
        configuration.height = max(Int((sourceHeight * outputScale).rounded()), 180)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let metadata = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first,
           let status = metadata[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }
        DispatchQueue.main.async { [weak self] in
            self?.preview?.display(sampleBuffer)
        }
    }
}

