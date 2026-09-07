import SwiftUI
import AVFoundation

/// SwiftUI view that displays the mirrored phone screen
/// using AVSampleBufferDisplayLayer for hardware-accelerated rendering.
///
/// The old `MirrorViewModel` is gone: its `start()` was a stub that set a bool
/// and its `connectionManager` was never assigned, so it neither received a
/// frame nor delivered a tap. `AppState` already owns both the decoder and the
/// connection, so this view talks to it directly.
struct MirrorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Connection status bar
            HStack {
                Circle()
                    .fill(appState.connectionState.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: toggleFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            // Mirror display
            GeometryReader { geometry in
                MirrorDisplayView(sinks: appState.videoSinks)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    // Taps are normalized against the *view's* size. The old code
                    // divided by the drag delta, which is the distance moved, not
                    // the surface — a tap (delta 0) was discarded outright and a
                    // drag produced a coordinate with no relation to the screen.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                                let dx = value.location.x - value.startLocation.x
                                let dy = value.location.y - value.startLocation.y
                                let start = normalized(value.startLocation, in: geometry.size)
                                let end = normalized(value.location, in: geometry.size)

                                if abs(dx) < 10 && abs(dy) < 10 {
                                    appState.sendTap(x: start.x, y: start.y)
                                } else {
                                    appState.sendSwipe(from: start, to: end)
                                }
                            }
                    )
            }
            .aspectRatio(appState.mirrorAspectRatio, contentMode: .fit)

            // Hardware-nav buttons: gesture-nav swipes don't come through a
            // mirrored surface, and the phone's bottom pill is easy to miss.
            HStack(spacing: 24) {
                navButton("chevron.left", "Back", .back)
                navButton("circle", "Home", .home)
                navButton("square.on.square", "Recents", .recents)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 300, minHeight: 500)
    }

    private func navButton(_ icon: String, _ label: String, _ key: BridgProtoInputEvent.EventType) -> some View {
        Button(action: { appState.sendKey(key) }) {
            Image(systemName: icon).font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .help(label)
        .disabled(!appState.connectionState.isConnected)
    }

    private var statusText: String {
        guard appState.connectionState.isConnected else { return appState.connectionState.displayText }
        return appState.isScreenMirroring ? "Mirroring" : "Start mirroring from the phone"
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// NSViewRepresentable that wraps AVSampleBufferDisplayLayer for video rendering.
struct MirrorDisplayView: NSViewRepresentable {
    let sinks: VideoSinks

    func makeNSView(context: Context) -> MirrorNSView {
        MirrorNSView(sinks: sinks)
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {}

    static func dismantleNSView(_ nsView: MirrorNSView, coordinator: ()) {
        nsView.detach()
    }
}

final class MirrorNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sinks: VideoSinks

    init(sinks: VideoSinks) {
        self.sinks = sinks
        super.init(frame: .zero)

        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        // Decoding happens off the main thread; layer work must not.
        sinks.attach(self) { [weak self] sampleBuffer in
            DispatchQueue.main.async { self?.enqueue(sampleBuffer) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // Let clicks fall through to SwiftUI. A plain NSView still claims every
    // mouse event that lands on it, which swallowed the DragGesture wrapped
    // around this view — so taps and swipes on the mirror did nothing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { sinks.detach(self) }

    func detach() { sinks.detach(self) }

    override func layout() {
        super.layout()
        // The sublayer does not inherit autoresizing from the view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // A decoder error latches the layer permanently; flushing clears it so a
        // later keyframe can start the picture again.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}
