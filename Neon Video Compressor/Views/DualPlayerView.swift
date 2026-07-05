//
//  DualPlayerView.swift
//  Stacks two AVPlayerLayers (encoded on top, original beneath) in one UIView and
//  cross-fades their opacity for the hold-to-compare gesture. SwiftUI's VideoPlayer
//  can't stack layers or hide its transport controls, so we drop to UIKit here.
//
import SwiftUI
import AVFoundation

struct DualPlayerView: UIViewRepresentable {
    let controller: PreviewController

    func makeUIView(context: Context) -> DualPlayerUIView {
        let v = DualPlayerUIView()
        v.encodedLayer.player = controller.encodedPlayer
        v.originalLayer.player = controller.originalPlayer
        return v
    }

    func updateUIView(_ v: DualPlayerUIView, context: Context) {
        v.setComparing(controller.isComparing)
    }
}

final class DualPlayerUIView: UIView {
    let encodedLayer = AVPlayerLayer()
    let originalLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Order matters: original added first (beneath), encoded on top.
        for layer in [originalLayer, encodedLayer] {
            layer.videoGravity = .resizeAspect
            self.layer.addSublayer(layer)
        }
        // The original sits underneath and stays fully opaque; the encoded layer
        // on top is the one whose opacity we fade. At rest the (opaque) encoded
        // layer covers the original; fading it to 0 reveals the original beneath.
        originalLayer.opacity = 1
        encodedLayer.opacity = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // AVPlayerLayer doesn't autoresize — keep both pinned to bounds. Disable the
    // implicit animation so a rotation/layout change doesn't animate the resize.
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        encodedLayer.frame = bounds
        originalLayer.frame = bounds
        CATransaction.commit()
    }

    /// Instantly cut between the encoded clip and the original (both players stay
    /// running and time-synced, so the picture doesn't jump in time on the switch).
    func setComparing(_ comparing: Bool) {
        let target: Float = comparing ? 0 : 1   // encoded (top) opacity
        guard encodedLayer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no fade — hard cut
        encodedLayer.opacity = target
        CATransaction.commit()
    }
}
