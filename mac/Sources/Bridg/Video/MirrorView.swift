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

            // Mirror display. All pointer/keyboard input is handled inside
            // MirrorNSView: AppKit gives us trackpad scroll, pinch and key
            // events, which SwiftUI gestures on macOS do not.
            MirrorDisplayView(sinks: appState.videoSinks, appState: appState)
                .background(Color.black)
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

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// NSViewRepresentable that wraps AVSampleBufferDisplayLayer for video rendering.
struct MirrorDisplayView: NSViewRepresentable {
    let sinks: VideoSinks
    let appState: AppState

    func makeNSView(context: Context) -> MirrorNSView {
        MirrorNSView(sinks: sinks, appState: appState)
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {}

    static func dismantleNSView(_ nsView: MirrorNSView, coordinator: ()) {
        nsView.detach()
    }
}

final class MirrorNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sinks: VideoSinks
    private let appState: AppState

    /// Mouse-down anchor, used to tell a tap from a long press from a drag.
    private var pressOrigin: CGPoint?
    private var pressStart: Date?

    /// Trackpad gestures arrive as a stream of small deltas; they are summed
    /// and flushed as one phone gesture so we don't spam the wire (and the
    /// phone's gesture dispatcher) with a stroke per wheel tick.
    private var scrollDelta: CGSize = .zero
    private var pinchMagnification: CGFloat = 0
    private var flushTimer: Timer?

    init(sinks: VideoSinks, appState: AppState) {
        self.sinks = sinks
        self.appState = appState
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

    // Top-left origin, so view coordinates match the phone's.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressOrigin = convert(event.locationInWindow, from: nil)
        pressStart = Date()
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = pressOrigin, let started = pressStart else { return }
        pressOrigin = nil
        pressStart = nil

        let end = convert(event.locationInWindow, from: nil)
        let elapsed = Date().timeIntervalSince(started)
        let moved = hypot(end.x - origin.x, end.y - origin.y)

        if moved < Self.dragThreshold {
            if elapsed > Self.longPressSeconds {
                appState.sendLongPress(x: normalized(origin).x, y: normalized(origin).y)
            } else {
                appState.sendTap(x: normalized(origin).x, y: normalized(origin).y)
            }
        } else {
            // Match the real drag duration so a flick stays a flick.
            appState.sendSwipe(
                from: normalized(origin),
                to: normalized(end),
                durationMs: Int32(max(50, min(elapsed * 1000, 2000)))
            )
        }
    }

    /// Two-finger scroll → a swipe in the same direction the fingers moved.
    override func scrollWheel(with event: NSEvent) {
        scrollDelta.width += event.scrollingDeltaX
        scrollDelta.height += event.scrollingDeltaY
        scheduleFlush()
    }

    /// Trackpad pinch → a two-finger pinch on the phone.
    override func magnify(with event: NSEvent) {
        pinchMagnification += event.magnification
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushTrackpad() }
        }
    }

    private func flushTrackpad() {
        flushTimer = nil
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        if abs(scrollDelta.height) > 1 || abs(scrollDelta.width) > 1 {
            let end = CGPoint(x: center.x + scrollDelta.width, y: center.y + scrollDelta.height)
            appState.sendSwipe(
                from: normalized(center),
                to: normalized(end),
                durationMs: Self.scrollDurationMs
            )
            scrollDelta = .zero
        }

        if abs(pinchMagnification) > 0.01 {
            let endSpan = (Self.pinchBaseSpan * (1 + pinchMagnification)).clamped(to: 0.05...0.9)
            appState.sendPinch(
                center: normalized(center),
                startSpan: Self.pinchBaseSpan,
                endSpan: endSpan
            )
            pinchMagnification = 0
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd-shortcuts belong to the Mac app, not the phone.
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76: appState.sendKeycode(66)                   // Return / Enter → KEYCODE_ENTER
        case 51, 117: appState.sendKeycode(67)                  // Delete → KEYCODE_DEL
        case 53: appState.sendKey(.back)                        // Esc → Back
        default:
            guard let text = event.characters, !text.isEmpty else { return }
            appState.sendText(text)
        }
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / bounds.width, 0), 1),
            y: min(max(point.y / bounds.height, 0), 1)
        )
    }

    deinit { sinks.detach(self) }

    func detach() {
        flushTimer?.invalidate()
        sinks.detach(self)
    }

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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension MirrorNSView {
    static let dragThreshold: CGFloat = 10
    static let longPressSeconds: TimeInterval = 0.5
    static let flushInterval: TimeInterval = 0.05
    static let scrollDurationMs: Int32 = 60
    /// Fingers start this far apart (fraction of screen width) for a pinch.
    static let pinchBaseSpan: CGFloat = 0.3
}
