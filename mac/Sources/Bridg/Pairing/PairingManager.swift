import Foundation
import Darwin
import CoreImage.CIFilterBuiltins
import AppKit

/// Manages the pairing flow from the Mac side:
/// generating QR codes, handling PairRequest/PairResponse.
class PairingManager {
    private let keychainManager = KeychainManager()

    /// Generate a pairing token for display in QR code.
    func generatePairingToken() -> String {
        var tokenBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &tokenBytes)
        return Data(tokenBytes).base64EncodedString()
    }

    /// Create the QR code content string.
    ///
    /// The Mac's LAN address rides along in the QR. Bonjour/mDNS is link-local
    /// multicast and does not cross subnets, so on segmented networks (campus,
    /// office, guest Wi-Fi) discovery finds nothing even though the two devices
    /// can route to each other perfectly well. Carrying the address here means
    /// pairing never depends on discovery working.
    func createQrContent(token: String) -> String {
        let publicKey = keychainManager.getOrCreatePublicKey()
        let pubKeyB64 = publicKey.base64EncodedString()
        return "bridg://pair/\(pubKeyB64):\(token):\(Self.localIPAddress ?? ""):\(deviceName)"
    }

    /// First non-loopback IPv4 address on an active interface.
    static var localIPAddress: String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            candidates[String(cString: ptr.pointee.ifa_name)] = String(cString: host)
        }

        // Prefer Wi-Fi/Ethernet over VPN and virtual interfaces.
        for name in ["en0", "en1", "en2"] {
            if let address = candidates[name] { return address }
        }
        return candidates.values.first
    }

    /// Generate a QR code image from content string.
    func generateQRCode(from content: String, size: CGFloat = 300) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale to desired size
        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    /// Parse QR code content from scanned code.
    func parseQrContent(_ content: String) -> QRData? {
        guard content.hasPrefix("bridg://pair/") else { return nil }
        let payload = String(content.dropFirst("bridg://pair/".count))
        // The device name is last and may itself contain a colon.
        let parts = payload.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        guard let publicKey = Data(base64Encoded: String(parts[0])) else { return nil }

        return QRData(
            publicKey: publicKey,
            token: String(parts[1]),
            host: String(parts[2]),
            deviceName: String(parts[3])
        )
    }

    /// Create a PairRequest to send to the Android device.
    func createPairRequest(token: String) -> (BridgProtoPairRequest, Data) {
        let publicKey = keychainManager.getOrCreatePublicKey()

        var request = BridgProtoPairRequest()
        request.senderPubkey = publicKey
        request.deviceName = deviceName
        request.pairingToken = token

        return (request, publicKey)
    }

    /// Handle an incoming PairRequest and create a PairResponse.
    func handlePairRequest(_ request: BridgProtoPairRequest, expectedToken: String) -> BridgProtoPairResponse? {
        guard request.pairingToken == expectedToken else {
            print("Pairing token mismatch — possible MITM attack")
            return nil
        }

        let publicKey = keychainManager.getOrCreatePublicKey()

        var response = BridgProtoPairResponse()
        response.responderPubkey = publicKey
        response.deviceName = deviceName
        response.accepted = true

        return response
    }

    /// Complete pairing by storing the paired device.
    func completePairing(peerPublicKey: Data, deviceName: String) {
        keychainManager.savePairedDevice(name: deviceName, publicKey: peerPublicKey)
        print("Paired with device: \(deviceName)")
    }

    private var deviceName: String {
        // Colons separate the QR fields, so they cannot appear inside a field.
        (Host.current().localizedName ?? "Mac").replacingOccurrences(of: ":", with: "-")
    }

    struct QRData {
        let publicKey: Data
        let token: String
        let host: String
        let deviceName: String
    }
}
