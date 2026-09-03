import Foundation

/// Length-prefixed framing: 4-byte big-endian length + payload bytes.
enum FrameCodec {
    // Video keyframes blow well past 64 KB; the old 64 KB cap silently dropped them.
    static let maxFrameSize = 4 * 1024 * 1024

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }
}

/// Accumulates bytes off a TCP stream and hands back whole frames.
/// TCP has no message boundaries — a single read can carry half a frame or three
/// of them, so a decoder that assumes "one read == one frame" corrupts everything.
final class FrameBuffer {
    enum FrameError: Error { case oversized(UInt32) }

    private var buffer = Data()

    func append(_ data: Data) { buffer.append(data) }

    /// Next complete frame, or nil if more bytes are still needed.
    func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }

        // Every index here is relative to startIndex: `removeFirst` does not
        // rebase a Data's indices, so after the first frame the buffer no longer
        // starts at 0 and absolute subscripts read past the end.
        let start = buffer.startIndex

        // Byte-wise read: `load(as: UInt32.self)` needs 4-byte alignment that a
        // Data slice does not guarantee.
        let length = buffer[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(FrameCodec.maxFrameSize) else { throw FrameError.oversized(length) }

        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }

        let payload = Data(buffer[(start + 4)..<(start + total)])
        buffer.removeFirst(total)
        return payload
    }

    func reset() { buffer.removeAll(keepingCapacity: false) }
}
