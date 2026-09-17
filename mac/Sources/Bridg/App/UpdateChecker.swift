import AppKit

/// "Check for Updates…": asks GitHub for the latest release, downloads its DMG
/// to ~/Downloads and opens it so the user can drag the new Bridg into Applications.
///
/// ponytail: no in-place swap and relaunch. Replacing a running, signed bundle
/// safely is Sparkle's job; add Sparkle if the drag step turns out to annoy people.
enum UpdateChecker {
    private static let latest = URL(string: "https://api.github.com/repos/HardikShreays/Bridg/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    @MainActor
    static func check() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        do {
            let (data, _) = try await URLSession.shared.data(from: latest)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let tag = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard isNewer(tag, than: current),
                  let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                alert("Bridg \(current) is up to date.")
                return
            }
            guard alert("Bridg \(tag) is available", info: "You have \(current). Download it now?", ok: "Download") else { return }

            let (tmp, _) = try await URLSession.shared.download(from: dmg.browser_download_url)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = downloads.appendingPathComponent("Bridg-\(tag).dmg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            NSWorkspace.shared.open(dest)
        } catch {
            alert("Couldn't check for updates", info: error.localizedDescription)
        }
    }

    /// "0.10.0" > "0.9.3": numeric, part by part; missing parts count as 0.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let a = parse(latest), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Menu bar app: activate first or the alert opens behind other windows.
    @MainActor @discardableResult
    private static func alert(_ title: String, info: String = "", ok: String = "OK") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        if ok != "OK" { alert.addButton(withTitle: "Later") }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
