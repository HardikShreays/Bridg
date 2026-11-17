import Foundation
import AppKit
import UniformTypeIdentifiers

/// Principal class of the "Bridg" share extension.
///
/// This is what makes Bridg appear in Finder's right-click "Share" submenu
/// (next to AirDrop, Mail, Messages…). The extension has no UI: it copies the
/// shared items into the app's ShareInbox and wakes the app, which then
/// transfers them to the selected phone.
///
/// The extension is a separate, short-lived process — it cannot reach the
/// running app's ConnectionManager — so the handoff is deliberately dumb:
/// files first, then a wake. The app drains the inbox when it sees either of
/// the two wake signals below (and again whenever a phone connects, so a
/// share that arrived while offline still goes out).
@objc(ShareExtension)
final class ShareExtension: NSObject, NSExtensionRequestHandling {
    private var context: NSExtensionContext?
    private var inbox = FileManager.default.temporaryDirectory

    /// `pending`/`finished` are touched from beginRequest and from the
    /// NSItemProvider callbacks, which arrive on arbitrary queues.
    private let lock = NSLock()
    private var pending = 0
    private var finished = false

    func beginRequest(with context: NSExtensionContext) {
        self.context = context
        inbox = Self.inboxURL()
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        for provider in providers {
            export(provider)
        }

        // Safety net: if a provider never calls back, finish anyway. The
        // extension process is killed shortly after completeRequest, so
        // hanging here would make the share silently fail. Idempotent with
        // the callback-driven path below.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish()
        }
    }

    // MARK: - Exporting

    private func export(_ provider: NSItemProvider) {
        // Order matters: a file usually also advertises plain-text and data
        // representations, so prefer the richest one that carries the
        // original file.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            exportFile(provider)
        } else if let dataType = firstDataType(provider) {
            exportData(provider, typeIdentifier: dataType)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            exportURL(provider)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            exportText(provider)
        }
    }

    /// A file dragged from Finder (or a document from another app).
    private func exportFile(_ provider: NSItemProvider) {
        beginOne()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            defer { self?.endOne() }
            guard let url = Self.fileURL(from: item) else { return }

            // Some sources hand us security-scoped URLs; harmless (returns
            // false) when the file is plain user-accessible.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let stamp = Self.stamp()
            let dest = self?.inbox.appendingPathComponent("\(stamp) \(url.lastPathComponent)") ?? URL(fileURLWithPath: "/dev/null")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                return
            }
        }
    }

    /// Raw data representations (images and files shared as data).
    private func exportData(_ provider: NSItemProvider, typeIdentifier: String) {
        beginOne()
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            defer { self?.endOne() }
            guard let url, let inbox = self?.inbox else { return }

            // The temp URL is only valid inside this callback — copy now.
            let stamp = Self.stamp()
            let dest = inbox.appendingPathComponent("\(stamp) \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    /// A web link (e.g. from Safari's share sheet).
    private func exportURL(_ provider: NSItemProvider) {
        beginOne()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
            defer { self?.endOne() }
            guard let self else { return }
            let url = (item as? URL)
                ?? (item as? Data).flatMap { try? URL(dataRepresentation: $0, relativeTo: nil) }
                ?? (item as? String).flatMap { URL(string: $0) }
            guard let url else { return }
            self.writeString(url.absoluteString, name: "Shared Link")
        }
    }

    /// Plain text from another app's share sheet, wrapped as a .txt file.
    private func exportText(_ provider: NSItemProvider) {
        beginOne()
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
            defer { self?.endOne() }
            guard let self else { return }
            let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            guard let text else { return }
            self.writeString(text, name: "Shared Text")
        }
    }

    // MARK: - Handoff

    /// Once everything is copied: wake the app and hand control back.
    ///
    /// Two wake signals, because either may miss: the URL launch works when
    /// the app is not running at all (SwiftUI delivers `bridg://` at launch),
    /// while the distributed notification reaches an already-running app even
    /// with no window open. The app also re-checks the inbox whenever a phone
    /// connects, so nothing is lost if both are missed.
    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        if let url = URL(string: "bridg://share-inbox") {
            NSWorkspace.shared.open(url)
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.bridg.share.inbox"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        context?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Helpers

    private func beginOne() {
        lock.lock()
        pending += 1
        lock.unlock()
    }

    private func endOne() {
        lock.lock()
        let last = pending > 0
        if last { pending -= 1 }
        let complete = last && pending == 0 && !finished
        lock.unlock()
        if complete {
            // Small delay so the last file's copy is safely on disk.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finish()
            }
        }
    }

    private func writeString(_ string: String, name: String) {
        let dest = inbox.appendingPathComponent("\(Self.stamp()) \(name).txt")
        try? string.write(to: dest, atomically: true, encoding: .utf8)
    }

    private func firstDataType(_ provider: NSItemProvider) -> String? {
        // UTTypeConformsTo rather than UTType(identifier:): the latter's
        // signature churns between SDKs (optional/throwing/allowUndeclared).
        let dataIdentifier = UTType.data.identifier as CFString
        return provider.registeredTypeIdentifiers.first {
            UTTypeConformsTo($0 as CFString, dataIdentifier)
        } ?? (provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) ? UTType.data.identifier : nil)
    }

    static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        if let string = item as? String, let url = URL(string: string), url.isFileURL { return url }
        return nil
    }

    /// The inbox lives INSIDE the extension's own sandbox container:
    /// ~/Library/Containers/com.bridg.mac.BridgShare/Data/Library/Application
    /// Support/Bridg/ShareInbox.
    ///
    /// It used to be the real home directory via a temporary-exception
    /// entitlement, but that cannot work: in a sandboxed process
    /// homeDirectoryForCurrentUser resolves to the container home, and the
    /// temporary exception itself is not honored for code signed without a
    /// provisioning profile — every write to the real inbox was denied, so
    /// shares silently never arrived. Writes inside the extension's own
    /// container, on the other hand, are always allowed; the app is not
    /// sandboxed, so it reads the container path directly (see AppState.swift).
    static func inboxURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridg", isDirectory: true)
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss.SSS"
        return formatter.string(from: Date())
    }
}
