package com.bridg.transport

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Handles length-prefixed protobuf framing on a TCP socket.
 * Frame format: 4-byte big-endian length + payload bytes.
 */
object FrameCodec {

    const val MAX_FRAME_SIZE = 4 * 1024 * 1024 // must match the Mac; video keyframes exceed 64 KB

    /**
     * Write a length-prefixed frame to the output stream.
     */
    @Throws(IOException::class)
    fun writeFrame(output: DataOutputStream, payload: ByteArray) {
        if (payload.size > MAX_FRAME_SIZE) {
            throw IOException("Frame too large: ${payload.size} bytes (max $MAX_FRAME_SIZE)")
        }
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }

    /**
     * Read a length-prefixed frame from the input stream.
     * Returns null if the stream is closed.
     */
    @Throws(IOException::class)
    fun readFrame(input: DataInputStream): ByteArray? {
        val length = try {
            input.readInt()
        } catch (e: IOException) {
            return null // Stream closed
        }

        if (length < 0 || length > MAX_FRAME_SIZE) {
            throw IOException("Invalid frame length: $length")
        }

        val payload = ByteArray(length)
        input.readFully(payload)
        return payload
    }
}
