import Foundation
import AppKit
import CryptoKit

/// Manages file transfers on the Mac side.
/// Supports sending files (drag-and-drop onto app) and receiving files.
class FileTransferManager {
    private let downloadDirectory: URL
    private var activeTransfers: [String: TransferState] = [:]

    var onTransferStarted: ((String, String, Int64) -> Void)?
    var onTransferProgress: ((String, Int64, Int64) -> Void)?
    var onTransferCompleted: ((String, URL) -> Void)?
    var onTransferError: ((String, String) -> Void)?

    /// Set by AppState. Without it the manager computed chunks and threw them away.
    var onSendEnvelope: ((BridgProtoEnvelope) -> Void)?

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        downloadDirectory = downloads.appendingPathComponent("Bridg")

        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Sending

    /// Start sending a file to Android.
    func sendFile(url: URL) {
        let filename = url.lastPathComponent
        let transferId = UUID().uuidString

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            onTransferError?(transferId, "Cannot read file attributes")
            return
        }

        let checksum = computeChecksum(url: url)

        var startMsg = BridgProtoFileTransferStart()
        startMsg.filename = filename
        startMsg.size = UInt64(fileSize)
        startMsg.checksum = checksum
        startMsg.transferID = transferId
        startMsg.mimeType = mimeType(for: url)

        let state = TransferState(
            id: transferId,
            filename: filename,
            totalSize: fileSize,
            url: url,
            expectedChecksum: checksum
        )
        activeTransfers[transferId] = state

        onTransferStarted?(transferId, filename, fileSize)

        var envelope = BridgProtoEnvelope()
        envelope.fileStart = startMsg
        onSendEnvelope?(envelope)

        sendChunks(state: state)
    }

    /// Handle a FileTransferAck from Android.
    func handleAck(_ ack: BridgProtoFileTransferAck) {
        let transferId = ack.transferID

        guard let state = activeTransfers[transferId] else { return }

        if ack.complete {
            activeTransfers.removeValue(forKey: transferId)
            onTransferCompleted?(transferId, state.url)
        } else if !ack.error.isEmpty {
            // Only an error triggers a resend; a plain progress ack is not a
            // request to restart the stream from that offset.
            activeTransfers.removeValue(forKey: transferId)
            onTransferError?(transferId, ack.error)
        } else {
            onTransferProgress?(transferId, Int64(ack.bytesReceived), state.totalSize)
        }
    }

    // MARK: - Receiving

    /// Handle a FileTransferStart from Android.
    func handleTransferStart(_ start: BridgProtoFileTransferStart) {
        let transferId = start.transferID
        let filename = sanitizeFilename(start.filename)
        let targetURL = uniqueURL(for: filename)

        let state = TransferState(
            id: transferId,
            filename: filename,
            totalSize: Int64(start.size),
            url: targetURL,
            expectedChecksum: start.checksum
        )
        activeTransfers[transferId] = state

        // FileHandle(forWritingTo:) throws unless the file already exists.
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)

        onTransferStarted?(transferId, filename, Int64(start.size))
    }

    /// Handle a FileChunk from Android.
    func handleFileChunk(_ chunk: BridgProtoFileChunk) -> BridgProtoFileTransferAck {
        var ack = BridgProtoFileTransferAck()
        ack.transferID = chunk.transferID

        guard let state = activeTransfers[chunk.transferID] else {
            ack.error = "Unknown transfer"
            return ack
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: state.url)
            fileHandle.seek(toFileOffset: UInt64(chunk.offset))
            fileHandle.write(chunk.data)
            fileHandle.closeFile()

            let bytesReceived = Int64(chunk.offset) + Int64(chunk.data.count)
            ack.bytesReceived = UInt64(bytesReceived)

            if bytesReceived >= state.totalSize {
                // The phone does not send a checksum. Comparing against an empty
                // expected value failed every single phone→Mac transfer at the
                // last chunk, so only verify when one was actually supplied.
                if !state.expectedChecksum.isEmpty,
                   computeChecksum(url: state.url) != state.expectedChecksum {
                    ack.error = "Checksum mismatch"
                    onTransferError?(chunk.transferID, "Checksum mismatch")
                } else {
                    ack.complete = true
                    activeTransfers.removeValue(forKey: chunk.transferID)
                    onTransferCompleted?(chunk.transferID, state.url)
                }
            } else {
                onTransferProgress?(chunk.transferID, bytesReceived, state.totalSize)
            }
        } catch {
            ack.error = error.localizedDescription
            onTransferError?(chunk.transferID, error.localizedDescription)
        }

        return ack
    }

    // MARK: - Drag and Drop Entry Point

    func handleDroppedFiles(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL else { continue }
            sendFile(url: url)
        }
    }

    // MARK: - Private

    private func sendChunks(state: TransferState, fromOffset offset: Int64 = 0) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let chunkSize = 64 * 1024 // 64KB

            guard let fileHandle = try? FileHandle(forReadingFrom: state.url) else { return }
            defer { fileHandle.closeFile() }

            fileHandle.seek(toFileOffset: UInt64(offset))
            var currentOffset = offset

            while currentOffset < state.totalSize {
                let bytesToRead = min(chunkSize, Int(state.totalSize - currentOffset))
                guard let data = try? fileHandle.read(upToCount: bytesToRead), !data.isEmpty else { break }

                var chunk = BridgProtoFileChunk()
                chunk.transferID = state.id
                chunk.offset = UInt64(currentOffset)
                chunk.data = data

                var envelope = BridgProtoEnvelope()
                envelope.fileChunk = chunk
                self.onSendEnvelope?(envelope)

                currentOffset += Int64(data.count)
                self.onTransferProgress?(state.id, currentOffset, state.totalSize)
            }

            fileHandle.closeFile()
        }
    }

    private func computeChecksum(url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return filename.components(separatedBy: invalid).joined()
    }

    private func uniqueURL(for filename: String) -> URL {
        var url = downloadDirectory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let nameWithoutExt = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            url = downloadDirectory.appendingPathComponent("\(nameWithoutExt)_\(counter).\(ext)")
            counter += 1
        }
        return url
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    struct TransferState {
        let id: String
        let filename: String
        let totalSize: Int64
        let url: URL
        var bytesTransferred: Int64 = 0
        var expectedChecksum: String = ""
    }
}
