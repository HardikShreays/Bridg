import AppKit

/// Monitors the Mac clipboard and syncs with the connected Android device.
/// Uses NSPasteboard.changeCount polling with echo prevention.
class ClipboardSync {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    /// Text we just wrote from a remote update — the next change event for it is our own echo.
    private var appliedFromRemote: String?
    private var isActive = true

    /// Stable per-install id. This used to be read from a key nothing ever wrote,
    /// and the fallback minted a fresh UUID on every single poll.
    private let deviceID: String = {
        if let existing = UserDefaults.standard.string(forKey: "device_id") { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: "device_id")
        return generated
    }()

    var onClipboardChanged: ((BridgProtoClipboardUpdate) -> Void)?

    /// Start polling the clipboard for changes.
    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        scheduleTimer(interval: 0.5)
    }

    /// Stop monitoring.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Set active state (back off when app is idle).
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        scheduleTimer(interval: active ? 0.5 : 2.0)
    }

    /// `Timer.scheduledTimer` only runs in `.default` run loop mode. Any time
    /// the app spends in another mode — tracking a menu, a Network.framework
    /// callback, anything AppKit does internally — the timer stalls until the
    /// run loop returns to `.default`, which in practice can mean it never
    /// fires again. `.common` covers every mode the timer needs to survive in.
    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.current.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Handle a clipboard update received from Android.
    func handleRemoteClipboard(_ update: BridgProtoClipboardUpdate) {
        // Echo prevention is the origin id alone. The old timestamp guard rejected
        // anything less than 2s old — i.e. every real clipboard update.
        guard update.originID != deviceID else { return }

        appliedFromRemote = update.content

        // Set clipboard content
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if !update.content.isEmpty {
            pasteboard.setString(update.content, forType: .string)
        }

        if !update.imageData.isEmpty {
            if let image = NSImage(data: update.imageData) {
                pasteboard.writeObjects([image])
            }
        }

        lastChangeCount = pasteboard.changeCount

        // Store in clipboard history
        saveToHistory(content: update.content, origin: .remote)
    }

    /// Get clipboard history.
    func getHistory(limit: Int = 20) -> [ClipboardItem] {
        let items = (UserDefaults.standard.array(forKey: "clipboard_history") as? [[String: Any]]) ?? []
        return items.prefix(limit).compactMap { dict in
            guard let content = dict["content"] as? String,
                  let timestamp = dict["timestamp"] as? TimeInterval else {
                return nil
            }
            return ClipboardItem(
                content: content,
                timestamp: Date(timeIntervalSince1970: timestamp),
                origin: (dict["origin"] as? String) == "local" ? .local : .remote
            )
        }
    }

    // MARK: - Private

    private func checkClipboard() {
        guard isActive else { return }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Don't echo back the item we just applied from the phone.
        if let applied = appliedFromRemote, pasteboard.string(forType: .string) == applied {
            appliedFromRemote = nil
            return
        }
        appliedFromRemote = nil

        var update = BridgProtoClipboardUpdate()
        update.originID = deviceID
        update.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        if let text = pasteboard.string(forType: .string) {
            update.content = text
            update.mimeType = "text/plain"

            saveToHistory(content: text, origin: .local)
            onClipboardChanged?(update)
        }

        // Handle images (check for image data up to max size)
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let image = images.first {
            if let tiffData = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]) {
                if pngData.count <= ClipboardSync.maxImageSize {
                    update.imageData = pngData
                    update.mimeType = "image/png"
                    onClipboardChanged?(update)
                }
            }
        }
    }

    private func saveToHistory(content: String, origin: Origin) {
        var items = (UserDefaults.standard.array(forKey: "clipboard_history") as? [[String: Any]]) ?? []

        items.insert([
            "content": content,
            "timestamp": Date().timeIntervalSince1970,
            "origin": origin == .local ? "local" : "remote"
        ], at: 0)

        // Keep only last 20 items
        if items.count > 20 {
            items = Array(items.prefix(20))
        }

        UserDefaults.standard.set(items, forKey: "clipboard_history")
    }

    enum Origin { case local, remote }

    static let maxImageSize = 5 * 1024 * 1024 // 5MB
}

struct ClipboardItem: Identifiable {
    let id = UUID()
    let content: String
    let timestamp: Date
    let origin: ClipboardSync.Origin
}
