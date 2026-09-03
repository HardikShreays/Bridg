import Foundation
import CoreMedia

/// Turns the phone's Annex-B H.264 stream into `CMSampleBuffer`s.
///
/// There is no `VTDecompressionSession` here any more. The old one existed but
/// its output callback body was empty — every decoded frame was thrown away —
/// and the `CMBlockBuffer` feeding it was built over a local `Data` with
/// `kCFAllocatorNull`, i.e. it pointed at freed memory the moment `decode`
/// returned. `AVSampleBufferDisplayLayer` decodes H.264 in hardware on its own,
/// so handing it sample buffers directly is both correct and much less code.
final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var frameCount: Int64 = 0

    /// Emitted on the thread `decode` is called from.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Natural size of the stream, once SPS/PPS have been seen.
    var displaySize: CGSize? {
        guard let formatDescription else { return nil }
        let d = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
    }

    /// Feed the codec-config buffer (SPS/PPS) that opens the stream.
    func configure(spsPps: Data) {
        ingestParameterSets(from: annexBNalUnits(in: spsPps))
    }

    func reset() {
        formatDescription = nil
        sps = nil
        pps = nil
        frameCount = 0
    }

    /// Feed one encoded frame.
    func decode(nalUnits: Data, pts: Int64, isKeyframe: Bool) {
        let nals = annexBNalUnits(in: nalUnits)

        // Some encoders repeat SPS/PPS ahead of every keyframe rather than only
        // in the config buffer; pick them up wherever they turn up.
        ingestParameterSets(from: nals)

        guard let formatDescription else { return }

        // AVCC: each NAL prefixed with its 4-byte big-endian length. Parameter
        // sets live in the format description, not in the sample.
        var avcc = Data()
        for nal in nals {
            let type = nal[nal.startIndex] & 0x1F
            guard type != 7, type != 8 else { continue }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        // The block buffer owns a copy. Nothing here may outlive this function's
        // stack — that was the previous implementation's use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return }

        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copied == noErr else { return }

        // The phone's PTS is in microseconds.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // Display immediately — this is a live mirror, not playback, so there is
        // no clock to schedule against.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        frameCount += 1
        onSampleBuffer?(sampleBuffer)
    }

    // MARK: - Private

    private func ingestParameterSets(from nals: [Data]) {
        var changed = false
        for nal in nals {
            switch nal[nal.startIndex] & 0x1F {
            case 7 where nal != sps: sps = nal; changed = true
            case 8 where nal != pps: pps = nal; changed = true
            default: break
            }
        }
        guard changed, let sps, let pps else { return }

        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                var pointers = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        if status == noErr { formatDescription = format }
        else { print("Format description failed: \(status)") }
    }

    /// Split an Annex-B buffer on its 3- and 4-byte start codes.
    ///
    /// Replaces a hand-rolled scanner whose inner `start..<(count - 2)` range
    /// trapped outright on a trailing NAL shorter than 3 bytes.
    private func annexBNalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count > 3 else { return [] }

        var starts: [(offset: Int, prefix: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }

        return starts.enumerated().compactMap { index, start in
            let begin = start.offset + start.prefix
            let end = index + 1 < starts.count ? starts[index + 1].offset : bytes.count
            guard begin < end else { return nil }
            return Data(bytes[begin..<end])
        }
    }
}

/// Fan-out for decoded mirror frames.
///
/// The mirror is reachable from two places at once — the standalone "Phone
/// Mirror" window and the sidebar page in `ContentView` — so a single callback
/// slot would leave whichever attached first showing black.
final class VideoSinks {
    private var sinks: [ObjectIdentifier: (CMSampleBuffer) -> Void] = [:]

    func attach(_ owner: AnyObject, _ sink: @escaping (CMSampleBuffer) -> Void) {
        sinks[ObjectIdentifier(owner)] = sink
    }

    func detach(_ owner: AnyObject) {
        sinks.removeValue(forKey: ObjectIdentifier(owner))
    }

    func emit(_ sampleBuffer: CMSampleBuffer) {
        for sink in sinks.values { sink(sampleBuffer) }
    }
}
