import Foundation
import AppKit
import CryptoKit

/// Manages file transfers on the Mac side.
/// Supports sending files (drag-and-drop onto app) and receiving files.
class FileTransferManager {
    private let downloadDirectory: URL

    /// Touched from the network queue (incoming chunks and acks) and from the
    /// sender thread, so every access goes through the accessors below. A Swift
    /// Dictionary read concurrently with a write is a crash, not a stale read.
    private var activeTransfers: [String: TransferState] = [:]
    private let transfersLock = NSLock()

    /// id, filename, size, isOutgoing (true = we are sending it to the phone).
    var onTransferStarted: ((String, String, Int64, Bool) -> Void)?
    var onTransferProgress: ((String, Int64, Int64) -> Void)?
    var onTransferCompleted: ((String, URL) -> Void)?
    var onTransferError: ((String, String) -> Void)?

    /// Set by AppState. Without it the manager computed chunks and threw them away.
    /// The completion fires once the socket has taken the frame — that is what
    /// paces `sendChunks`.
    var onSendEnvelope: ((BridgProtoEnvelope, ((Bool) -> Void)?) -> Void)?

    init() {
        downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
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
        addTransfer(state)

        onTransferStarted?(transferId, filename, fileSize, true)

        var envelope = BridgProtoEnvelope()
        envelope.fileStart = startMsg
        onSendEnvelope?(envelope, nil)

        sendChunks(state: state)
    }

    /// Handle a FileTransferAck from Android.
    func handleAck(_ ack: BridgProtoFileTransferAck) {
        let transferId = ack.transferID

        guard let state = transfer(transferId) else { return }

        if ack.complete {
            removeTransfer(transferId)
            onTransferCompleted?(transferId, state.url)
        } else if !ack.error.isEmpty {
            // Only an error triggers a resend; a plain progress ack is not a
            // request to restart the stream from that offset.
            removeTransfer(transferId)
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
        addTransfer(state)

        // FileHandle(forWritingTo:) throws unless the file already exists.
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)

        onTransferStarted?(transferId, filename, Int64(start.size), false)
    }

    /// Handle a FileChunk from Android.
    func handleFileChunk(_ chunk: BridgProtoFileChunk) -> BridgProtoFileTransferAck {
        var ack = BridgProtoFileTransferAck()
        ack.transferID = chunk.transferID

        guard let state = transfer(chunk.transferID) else {
            ack.error = "Unknown transfer"
            return ack
        }

        // The phone streams strictly in order. A chunk that doesn't start
        // where the last one ended means one was dropped on the wire — fail
        // loudly instead of seeking past the gap and writing a corrupt file
        // that reports success.
        guard Int64(chunk.offset) == state.bytesTransferred else {
            removeTransfer(chunk.transferID)
            try? FileManager.default.removeItem(at: state.url)
            ack.error = "Out-of-order chunk (expected \(state.bytesTransferred), got \(chunk.offset))"
            onTransferError?(chunk.transferID, ack.error)
            return ack
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: state.url)
            fileHandle.seek(toFileOffset: UInt64(chunk.offset))
            fileHandle.write(chunk.data)
            fileHandle.closeFile()

            let bytesReceived = Int64(chunk.offset) + Int64(chunk.data.count)
            recordBytes(bytesReceived, for: chunk.transferID)
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
                    removeTransfer(chunk.transferID)
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

    private func transfer(_ id: String) -> TransferState? {
        transfersLock.lock(); defer { transfersLock.unlock() }
        return activeTransfers[id]
    }

    private func addTransfer(_ state: TransferState) {
        transfersLock.lock(); defer { transfersLock.unlock() }
        activeTransfers[state.id] = state
    }

    private func removeTransfer(_ id: String) {
        transfersLock.lock(); defer { transfersLock.unlock() }
        activeTransfers.removeValue(forKey: id)
    }

    private func recordBytes(_ bytes: Int64, for id: String) {
        transfersLock.lock(); defer { transfersLock.unlock() }
        activeTransfers[id]?.bytesTransferred = bytes
    }

    /// Stream the file out, one chunk at a time.
    ///
    /// Disk reads outrun the network by orders of magnitude, so the old version
    /// — read the whole file in a tight loop, hand every chunk to the socket —
    /// queued the entire file in memory before the first megabyte had left the
    /// Mac. Waiting for each chunk to be taken bounds that to one chunk. The
    /// phone has the same guard on its side, and calls it `sendBlocking`.
    private func sendChunks(state: TransferState, fromOffset offset: Int64 = 0) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let chunkSize = 64 * 1024 // 64KB

            guard let fileHandle = try? FileHandle(forReadingFrom: state.url) else {
                self.onTransferError?(state.id, "Cannot open file for reading")
                return
            }
            defer { fileHandle.closeFile() }

            fileHandle.seek(toFileOffset: UInt64(offset))
            var currentOffset = offset

            while currentOffset < state.totalSize {
                // A cancelled or failed transfer is dropped from the table;
                // stop reading rather than pushing at a peer that gave up.
                guard self.transfer(state.id) != nil else { return }

                let bytesToRead = min(chunkSize, Int(state.totalSize - currentOffset))
                guard let data = try? fileHandle.read(upToCount: bytesToRead), !data.isEmpty else { break }

                var chunk = BridgProtoFileChunk()
                chunk.transferID = state.id
                chunk.offset = UInt64(currentOffset)
                chunk.data = data

                var envelope = BridgProtoEnvelope()
                envelope.fileChunk = chunk

                let taken = DispatchSemaphore(value: 0)
                var ok = false
                self.onSendEnvelope?(envelope) { success in
                    ok = success
                    taken.signal()
                }
                taken.wait()
                guard ok else {
                    self.onTransferError?(state.id, "Connection lost mid-transfer")
                    return
                }

                currentOffset += Int64(data.count)
                self.onTransferProgress?(state.id, currentOffset, state.totalSize)
            }
        }
    }

    /// SHA-256 of a file, read incrementally.
    ///
    /// `Data(contentsOf:)` pulled the whole file into memory — for the sender
    /// that meant a second full copy of a file it was already streaming.
    private func computeChecksum(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { handle.closeFile() }

        var hasher = SHA256()
        while let block = try? handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
