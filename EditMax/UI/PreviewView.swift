import SwiftUI
import AVFoundation
import AppKit

/// The player's picture, aspect-fit. Titles, stills, color and transitions are all in the frames themselves (the compositor).
struct PreviewView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(player: controller.player) }
    func updateNSView(_ view: PlayerLayerView, context: Context) {}
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
