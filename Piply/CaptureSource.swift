import AppKit
import ScreenCaptureKit

struct CaptureSource: Identifiable {
    let window: SCWindow
    let applicationName: String
    let title: String
    let icon: NSImage
    let cropRect: CGRect?

    init(
        window: SCWindow,
        applicationName: String,
        title: String,
        icon: NSImage,
        cropRect: CGRect? = nil
    ) {
        self.window = window
        self.applicationName = applicationName
        self.title = title
        self.icon = icon
        self.cropRect = cropRect
    }

    var id: CGWindowID { window.windowID }
    var captureSize: CGSize { cropRect?.size ?? window.frame.size }

    func croppedToChromeViewport(
        viewportWidth: Double?,
        viewportHeight: Double?,
        outerWidth: Double?,
        outerHeight: Double?
    ) -> CaptureSource {
        guard let viewportWidth, let viewportHeight, let outerWidth, let outerHeight,
              viewportWidth > 0, viewportHeight > 0, outerWidth > 0, outerHeight > 0 else {
            return self
        }

        let fullSize = window.frame.size
        let scaleX = fullSize.width / CGFloat(outerWidth)
        let scaleY = fullSize.height / CGFloat(outerHeight)
        let horizontalChrome = max(CGFloat(outerWidth - viewportWidth), 0)
        let leftChrome = horizontalChrome <= 16 ? horizontalChrome / 2 : 0
        let topChrome = max(CGFloat(outerHeight - viewportHeight), 0)
        let proposed = CGRect(
            x: leftChrome * scaleX,
            y: topChrome * scaleY,
            width: CGFloat(viewportWidth) * scaleX,
            height: CGFloat(viewportHeight) * scaleY
        ).intersection(CGRect(origin: .zero, size: fullSize))

        guard proposed.width >= 100, proposed.height >= 80 else { return self }
        return CaptureSource(
            window: window,
            applicationName: applicationName,
            title: title,
            icon: icon,
            cropRect: proposed
        )
    }
}

