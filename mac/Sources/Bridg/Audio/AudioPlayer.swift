import AVFoundation
import Foundation

/// Plays the phone's mirrored audio.
///
/// The wire carries raw interleaved 16-bit PCM, so there is no decoder here —
/// just a conversion to the Float32 format AVAudioEngine schedules, and a
/// player node to hand it to.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = NSLock()

    /// Feed one PCM chunk. Safe to call from the network queue; the first call
    /// (and any format change) brings the engine up.
    func play(pcm: Data, sampleRate: UInt32, channels: UInt32) {
        guard sampleRate > 0, channels > 0, !pcm.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if format?.sampleRate != Double(sampleRate) || format?.channelCount != channels {
            start(sampleRate: Double(sampleRate), channels: channels)
        }
        guard let format, let buffer = makeBuffer(from: pcm, format: format) else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        player.stop()
        engine.stop()
        format = nil
    }

    // MARK: - Private

    private func start(sampleRate: Double, channels: UInt32) {
        player.stop()
        engine.stop()
        engine.reset()

        guard let newFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)
        ) else { return }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)

        do {
            try engine.start()
        } catch {
            print("Audio engine failed to start: \(error)")
            return
        }
        player.play()
        format = newFormat
    }

    /// Interleaved Int16 → the engine's deinterleaved Float32.
    /// Not private so the round-trip is testable without an audio device.
    func makeBuffer(from pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        let frames = pcm.count / (2 * channels)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            // The wire is little-endian and possibly unaligned, so read bytes
            // rather than binding the buffer to Int16.
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let index = (frame * channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                    output[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        return buffer
    }
}
