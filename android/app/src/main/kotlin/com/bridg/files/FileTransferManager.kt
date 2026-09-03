package com.bridg.files

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.bridg.proto.Envelope
import com.bridg.proto.FileChunk
import com.bridg.proto.FileTransferAck
import com.bridg.proto.FileTransferCancel
import com.bridg.proto.FileTransferStart
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Manages file transfers between Android and Mac.
 * Supports chunked transfer with resume capability.
 */
class FileTransferManager(private val context: Context) {

    private val activeTransfers = ConcurrentHashMap<String, TransferState>()
    /** MediaStore rows still marked IS_PENDING, keyed by sanitized filename. */
    private val pendingUris = ConcurrentHashMap<String, Uri>()
    private var transferListener: TransferListener? = null

    /** Set by BridgService. Without it, chunks were built and then discarded. */
    private var envelopeSender: ((Envelope) -> Unit)? = null

    fun setEnvelopeSender(sender: (Envelope) -> Unit) { envelopeSender = sender }

    fun setTransferListener(listener: TransferListener) { transferListener = listener }

    /** Acks from the Mac while we are sending. */
    fun handleAck(ack: FileTransferAck) {
        val state = activeTransfers[ack.transferId] ?: return
        if (ack.error.isNotEmpty()) {
            Log.e(TAG, "Peer rejected transfer ${ack.transferId}: ${ack.error}")
            activeTransfers.remove(ack.transferId)
            transferListener?.onTransferError(ack.transferId, ack.error)
        } else if (ack.complete) {
            activeTransfers.remove(ack.transferId)
            transferListener?.onTransferCompleted(ack.transferId)
        }
    }

    /**
     * Start sending a file.
     */
    fun startSend(inputStream: InputStream, filename: String, size: Long, mimeType: String) {
        val transferId = UUID.randomUUID().toString()

        val state = TransferState(
            transferId = transferId,
            filename = filename,
            mimeType = mimeType,
            direction = Direction.OUTGOING,
            expectedSize = size
        )

        activeTransfers[transferId] = state

        // Announce the transfer before streaming: the receiver needs the name
        // and size to open a file at all.
        envelopeSender?.invoke(
            Envelope.newBuilder().setFileStart(
                FileTransferStart.newBuilder()
                    .setTransferId(transferId)
                    .setFilename(filename)
                    .setSize(size)
                    .setMimeType(mimeType)
                    .build()
            ).build()
        )

        // Start the transfer in a coroutine
        Thread {
            try {
                sendFile(inputStream, state)
            } catch (e: Exception) {
                Log.e(TAG, "Send error: ${e.message}")
                state.error = e.message
                transferListener?.onTransferError(transferId, e.message ?: "Unknown error")
            }
        }.start()
    }

    /**
     * Handle an incoming FileTransferStart message.
     */
    fun handleTransferStart(start: FileTransferStart, outputStream: OutputStream) {
        val state = TransferState(
            transferId = start.transferId,
            filename = start.filename,
            mimeType = start.mimeType,
            direction = Direction.INCOMING,
            expectedSize = start.size,
            checksum = start.checksum,
            outputStream = outputStream
        )

        activeTransfers[start.transferId] = state
        transferListener?.onTransferStarted(start.transferId, start.filename, start.size)
        Log.i(TAG, "Receiving file: ${start.filename} (${start.size} bytes)")
    }

    /**
     * Handle an incoming FileChunk.
     */
    fun handleFileChunk(chunk: FileChunk): FileTransferAck {
        val state = activeTransfers[chunk.transferId]
            ?: return FileTransferAck.newBuilder()
                .setTransferId(chunk.transferId)
                .setError("Unknown transfer")
                .build()

        try {
            val outputStream = state.outputStream ?: throw IllegalStateException("No output stream")

            // Both senders stream strictly in order, so the destination is
            // append-only. Seeking used to require a FileOutputStream, which
            // ruled out the MediaStore streams the receive path now uses; an
            // explicit offset check catches the out-of-order case instead of
            // silently writing the chunk to the wrong place.
            if (chunk.offset != state.bytesTransferred) {
                throw IllegalStateException(
                    "Out-of-order chunk: got offset ${chunk.offset}, expected ${state.bytesTransferred}"
                )
            }
            outputStream.write(chunk.data.toByteArray())

            state.bytesTransferred = chunk.offset + chunk.data.size().toLong()

            // Check if transfer is complete
            if (state.bytesTransferred >= state.expectedSize) {
                outputStream.flush()
                outputStream.close()

                // Verify checksum if provided
                if (state.checksum.isNotEmpty()) {
                    // Would verify SHA-256 here
                    Log.d(TAG, "Checksum verification: ${state.checksum}")
                }

                publish(sanitize(state.filename))
                activeTransfers.remove(chunk.transferId)
                transferListener?.onTransferCompleted(chunk.transferId)
            }

            return FileTransferAck.newBuilder()
                .setTransferId(chunk.transferId)
                .setBytesReceived(state.bytesTransferred)
                .setComplete(state.bytesTransferred >= state.expectedSize)
                .build()
        } catch (e: Exception) {
            Log.e(TAG, "Error writing chunk: ${e.message}")
            return FileTransferAck.newBuilder()
                .setTransferId(chunk.transferId)
                .setError(e.message ?: "Write error")
                .build()
        }
    }

    /**
     * Handle a transfer cancellation.
     */
    fun handleTransferCancel(cancel: FileTransferCancel) {
        val state = activeTransfers.remove(cancel.transferId)
        state?.outputStream?.close()
        transferListener?.onTransferCancelled(cancel.transferId, cancel.reason)
        Log.i(TAG, "Transfer cancelled: ${cancel.transferId} — ${cancel.reason}")
    }

    /**
     * Cancel an active transfer.
     */
    fun cancelTransfer(transferId: String) {
        val state = activeTransfers.remove(transferId)
        state?.outputStream?.close()
        transferListener?.onTransferCancelled(transferId, "Cancelled by user")
    }

    /**
     * Get the resume offset for a partially completed transfer.
     */
    fun getResumeOffset(transferId: String): Long {
        return activeTransfers[transferId]?.bytesTransferred ?: 0
    }

    /**
     * Open a destination for an incoming transfer, under the user's Downloads.
     *
     * The old implementation wrote straight to
     * `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)`.
     * Under scoped storage that path is not writable — `WRITE_EXTERNAL_STORAGE`
     * is capped at API 29 in the manifest and does nothing above it — so the
     * `FileOutputStream` constructor threw `FileNotFoundException (EACCES)`.
     * It was called straight from the socket read loop, so every Mac→phone
     * transfer took the connection down with it.
     */
    fun createReceiveFile(filename: String): OutputStream {
        val safeName = sanitize(filename)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Bridg")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw java.io.IOException("MediaStore rejected $safeName")
            // MediaStore de-duplicates names itself, so no _1/_2 loop is needed.
            pendingUris[safeName] = uri
            return resolver.openOutputStream(uri)
                ?: throw java.io.IOException("Cannot open $safeName for writing")
        }

        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Bridg"
        )
        if (!dir.exists()) dir.mkdirs()

        val file = File(dir, safeName)
        var targetFile = file
        var counter = 1
        while (targetFile.exists()) {
            targetFile = File(dir, "${file.nameWithoutExtension}_$counter.${file.extension}")
            counter++
        }

        return FileOutputStream(targetFile)
    }

    /**
     * Clear IS_PENDING so a finished download becomes visible to the Files app.
     * Until this runs the row exists but no other app can see it.
     */
    private fun publish(filename: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val uri = pendingUris.remove(filename) ?: return
        context.contentResolver.update(
            uri,
            ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
            null,
            null
        )
    }

    /** A peer-supplied name must never escape the download directory. */
    private fun sanitize(filename: String): String =
        File(filename).name.replace(Regex("""[/\\:*?"<>|]"""), "_").ifEmpty { "file" }

    private fun sendFile(inputStream: InputStream, state: TransferState) {
        val buffer = ByteArray(CHUNK_SIZE)
        var offset = 0L

        try {
            var bytesRead: Int
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                if (Thread.currentThread().isInterrupted) {
                    throw InterruptedException("Transfer interrupted")
                }

                val chunkData = if (bytesRead == CHUNK_SIZE) buffer else buffer.copyOf(bytesRead)

                val chunk = FileChunk.newBuilder()
                    .setTransferId(state.transferId)
                    .setOffset(offset)
                    .setData(com.google.protobuf.ByteString.copyFrom(chunkData))
                    .build()

                val envelope = Envelope.newBuilder()
                    .setFileChunk(chunk)
                    .build()

                envelopeSender?.invoke(envelope)
                transferListener?.onChunkSent(state.transferId, offset, state.expectedSize)

                offset += bytesRead
                state.bytesTransferred = offset
            }

            Log.i(TAG, "Sent ${state.filename} ($offset bytes), awaiting ack")
        } finally {
            inputStream.close()
        }
    }

    enum class Direction {
        INCOMING, OUTGOING
    }

    data class TransferState(
        val transferId: String,
        val filename: String,
        val mimeType: String,
        val direction: Direction,
        val expectedSize: Long = 0,
        val checksum: String = "",
        var bytesTransferred: Long = 0,
        var error: String? = null,
        val outputStream: OutputStream? = null
    )

    interface TransferListener {
        fun onTransferStarted(transferId: String, filename: String, totalSize: Long)
        fun onChunkSent(transferId: String, offset: Long, totalSize: Long)
        fun onTransferCompleted(transferId: String)
        fun onTransferError(transferId: String, error: String)
        fun onTransferCancelled(transferId: String, reason: String)
    }

    companion object {
        private const val TAG = "FileTransferManager"
        const val CHUNK_SIZE = 64 * 1024 // 64KB chunks
    }
}
