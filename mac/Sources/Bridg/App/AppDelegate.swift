import Cocoa

/// The SwiftUI `MenuBarExtra` in BridgApp already owns the menu bar item, and
/// AppState already owns the connection — this delegate previously duplicated
/// both, giving two status icons and two competing listeners on port 18920.
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Holding this token for the app's whole life opts Bridg out of App Nap.
    ///
    /// Bridg is `LSUIElement` (no Dock icon, usually no visible window) and does
    /// all its real work in the background: a clipboard poll timer, the TCP
    /// connection's ping/pong, receiving frames. Without this, App Nap throttles
    /// that work to a near-standstill within seconds of launch — verified by an
    /// isolated test: with only the `RunLoop` `.common`-mode registration in
    /// `ClipboardSync` and no activity token, three separate clipboard changes
    /// over 90s produced zero syncs; with this token added, every one synced.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Maintaining the phone connection and syncing clipboard/notifications"
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

extension Notification.Name {
    static let openMirrorWindow = Notification.Name("openMirrorWindow")
}
