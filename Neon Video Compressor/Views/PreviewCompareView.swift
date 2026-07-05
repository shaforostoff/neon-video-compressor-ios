//
//  PreviewCompareView.swift
//  Full-screen preview: encodes the first few seconds (fastest preset) and loops
//  it. Hold to cross-fade to the original for an A/B quality check; double-tap or
//  pinch to zoom in and inspect detail.
//
import SwiftUI

struct PreviewCompareView: View {
    let job: EncodeJob

    @Environment(\.dismiss) private var dismiss
    @State private var controller = PreviewController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch controller.phase {
            case .encoding: encodingView
            case .ready:    readyView
            case .failed(let msg): failView(msg)
            }

            closeButton
        }
        .statusBarHidden()
        .onAppear { controller.start(job: job) }
        .onDisappear { controller.teardown() }
    }

    // MARK: states

    private var encodingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: controller.encodeFraction)
                .progressViewStyle(.linear)
                .frame(width: 200)
                .tint(.white)
            Text("Preparing preview…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func failView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 44)).foregroundStyle(.red)
            Text("Preview failed").font(.headline).foregroundStyle(.white)
            Text(msg).font(.footnote).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var readyView: some View {
        GeometryReader { geo in
            let fitted = fittedSize(aspect: controller.aspectRatio, in: geo.size)
            ZStack {
                DualPlayerView(controller: controller)
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(controller.scale)
                    .offset(controller.panOffset)
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(zoomGesture)
            .simultaneousGesture(doubleTapGesture)
            .simultaneousGesture(compareGesture)
            .simultaneousGesture(panGesture)
            .onAppear { controller.contentSize = fitted }
            .onChange(of: fitted) { _, new in controller.contentSize = new }
            .overlay(alignment: .bottom) { compareHint }
        }
        .ignoresSafeArea()
    }

    // MARK: gestures

    // Hold to compare — a short long-press qualifier so quick taps (and the
    // double-tap) don't flicker the crossfade; the drag tracks until release.
    private var compareGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, _) = value, controller.scale == 1 {
                    controller.isComparing = true
                }
            }
            .onEnded { _ in controller.isComparing = false }
    }

    // Pan only when zoomed; otherwise the single-finger drag belongs to compare.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in if controller.scale > 1 { controller.applyPan(v.translation) } }
            .onEnded { _ in controller.commitPan() }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in controller.applyMagnify(v.magnification) }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { controller.commitMagnify() } }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded { withAnimation(.easeInOut(duration: 0.2)) { controller.toggleZoom() } }
    }

    // MARK: chrome

    private var compareHint: some View {
        Text(controller.isComparing ? "Original" : "Hold to compare with original")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 40)
            .allowsHitTesting(false)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 8).padding(.trailing, 16)
            }
            Spacer()
        }
    }

    // MARK: helpers

    /// Fit the given aspect (w/h) inside `container`, centered. Falls back to the
    /// full container while the aspect is still unknown.
    private func fittedSize(aspect: CGFloat?, in container: CGSize) -> CGSize {
        guard let aspect, aspect > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            return CGSize(width: container.width, height: container.width / aspect)
        } else {
            return CGSize(width: container.height * aspect, height: container.height)
        }
    }
}
