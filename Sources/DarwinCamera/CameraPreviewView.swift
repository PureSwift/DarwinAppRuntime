import AVFoundation
import DynamicCamera
import RuntimeCamera
import SwiftUI

/// What a `CameraPreview` node shows (`RenderIR.md`): the picture of the
/// camera whose `identifier()` it carries, or nothing once the guest
/// released it or while it's off.
///
/// It fills its space and crops unless told to fit. The front camera's
/// picture is mirrored, as AVFoundation mirrors it. A tap focuses and sets
/// the exposure there, and a pinch zooms; the camera reports the zoom.
/// The camera stays on when the node goes.
struct CameraPreviewView: View {

    let identifier: Int32

    let fill: Bool

    var body: some View {
        if let engine = HostCameraCapture.camera(for: identifier)?.engine as? AVCameraEngine {
            PreviewLayerView(engine: engine, gravity: fill ? .resizeAspectFill : .resizeAspect)
        }
    }
}

#if os(iOS)
import UIKit

private struct PreviewLayerView: UIViewRepresentable {

    let engine: AVCameraEngine

    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewUIView.tapped(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: view, action: #selector(PreviewUIView.pinched(_:))))
        update(view)
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        update(view)
    }

    private func update(_ view: PreviewUIView) {
        view.engine = engine
        if view.previewLayer.session !== engine.session {
            view.previewLayer.session = engine.session
        }
        view.previewLayer.videoGravity = gravity
    }
}

final class PreviewUIView: UIView {

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    weak var engine: AVCameraEngine?

    override func layoutSubviews() {
        super.layoutSubviews()
        // The picture turns with the interface, as everything else does.
        guard let connection = previewLayer.connection, let orientation = window?.windowScene?.interfaceOrientation else { return }
        let upright: CameraValues.Upright
        switch orientation {
        case .portraitUpsideDown: upright = .upsideDown
        case .landscapeLeft: upright = .landscapeRight
        case .landscapeRight: upright = .landscapeLeft
        default: upright = .portrait
        }
        if #available(iOS 17, *) {
            if connection.isVideoRotationAngleSupported(upright.rotationAngle) {
                connection.videoRotationAngle = upright.rotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = upright.videoOrientation
        }
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: self))
        engine?.focus(at: point)
    }

    @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            engine?.pinchBegan()
            engine?.pinchChanged(Double(recognizer.scale))
        case .changed:
            engine?.pinchChanged(Double(recognizer.scale))
        default:
            break
        }
    }
}

#elseif os(macOS)
import AppKit

private struct PreviewLayerView: NSViewRepresentable {

    let engine: AVCameraEngine

    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.addGestureRecognizer(NSClickGestureRecognizer(target: view, action: #selector(PreviewNSView.clicked(_:))))
        update(view)
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        update(view)
    }

    private func update(_ view: PreviewNSView) {
        view.engine = engine
        if view.previewLayer.session !== engine.session {
            view.previewLayer.session = engine.session
        }
        view.previewLayer.videoGravity = gravity
    }
}

final class PreviewNSView: NSView {

    let previewLayer = AVCaptureVideoPreviewLayer()

    weak var engine: AVCameraEngine?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: the layer first, then asking for one.
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: self))
        engine?.focus(at: point)
    }
}
#endif
