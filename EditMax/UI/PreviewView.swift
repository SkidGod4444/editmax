import SwiftUI
import AVFoundation
import AppKit

/// AVPlayerLayer plus the synchronized overlay layer, scaled to the visible video rect.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController

    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(player: controller.player) }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.install(sync: controller.syncLayer, renderSize: controller.renderSize)
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    private var sync: AVSynchronizedLayer?
    private var renderSize = CGSize(width: 1920, height: 1080)
    private var observation: NSKeyValueObservation?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        observation = playerLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.layoutOverlay() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func install(sync newSync: AVSynchronizedLayer?, renderSize: CGSize) {
        self.renderSize = renderSize
        if sync !== newSync {
            sync?.removeFromSuperlayer()
            sync = newSync
            if let newSync { layer?.addSublayer(newSync) }
        }
        layoutOverlay()
    }

    override func layout() { super.layout(); playerLayer.frame = bounds; layoutOverlay() }

    private func layoutOverlay() {
        guard let sync else { return }
        var rect = playerLayer.videoRect
        if rect.isEmpty {  // before first frame: aspect-fit by hand
            let scale = min(bounds.width / renderSize.width, bounds.height / renderSize.height)
            let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
            rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sync.bounds = CGRect(origin: .zero, size: renderSize)
        sync.position = CGPoint(x: rect.midX, y: rect.midY)
        let s = rect.width / max(1, renderSize.width)
        sync.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}
