import SwiftUI

/// Bridg — Android↔Mac Bridge
/// Menu bar app that provides screen mirroring, file transfer,
/// clipboard sync, and notification forwarding.
@main
struct BridgApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar item
        MenuBarExtra {
            BridgMenuBarView()
                .environmentObject(appState)
        } label: {
            Image(nsImage: .bridgMark)
                .accessibilityLabel("Bridg")
        }
        // The default .menu style renders buttons as menu items and silently
        // drops everything else — the dial field never appeared.
        .menuBarExtraStyle(.window)

        // Main window (accessible from menu bar)
        Window("Bridg", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 800, height: 600)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // Mirror window
        Window("Phone Mirror", id: "mirror") {
            MirrorView()
                .environmentObject(appState)
        }
        .defaultSize(width: 400, height: 800)
        .handlesExternalEvents(matching: ["mirror"])
    }
}

extension NSImage {
    /// The Bridg mark for the menu bar: assets/logo.svg's arch, deck and
    /// hangers, without the tile. A template, so macOS tints it for light and
    /// dark menu bars. Keep the coordinates in step with the SVG.
    static let bridgMark: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 12), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // SVG units → points: the deck (x 196…828) spans 20 pt.
            let s: CGFloat = 20 / 632
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 1 + (x - 196) * s, y: 2.4 + (y - 382) * s) }

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            let span = CGMutablePath()
            span.move(to: p(230, 612))
            span.addQuadCurve(to: p(794, 612), control: p(512, 152))
            span.move(to: p(196, 612))
            span.addLine(to: p(828, 612))
            ctx.setLineWidth(2)
            ctx.addPath(span)
            ctx.strokePath()

            let hangers = CGMutablePath()
            for (x, top) in [(371.0, 440.0), (512, 382), (653, 440)] {
                hangers.move(to: p(x, top))
                hangers.addLine(to: p(x, 612))
            }
            ctx.setLineWidth(1.25)
            ctx.addPath(hangers)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
