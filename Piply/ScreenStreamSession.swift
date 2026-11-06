import AVFoundation
import ScreenCaptureKit

final class ScreenStreamSession: NSObject, SCStreamOutput {
    private let window: SCWindow
    private weak var preview: CapturePreviewView?
    private let outputQueue = DispatchQueue(label: "com.naru.piply.video", qos: .userInteractive)
    private var stream: SCStream?

    init(window: SCWindow, preview: CapturePreviewView) {
        self.window = window
        self.preview = preview
    }

    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(Int((filter.contentRect.width * scale).rounded()), 320)
        configuration.height = max(Int((filter.contentRect.height * scale).rounded()), 180)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
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

