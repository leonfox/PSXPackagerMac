import AVFoundation
import PSXCore

/// Plays a CD audio track straight from its disc image (a .bin, a .chd or a disc inside an EBOOT).
final class CDAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var cancellation: CancellationToken?
    private let lock = NSLock()
    private var startedAt: AVAudioFramePosition = 0
    private(set) var totalSeconds: Double = 0

    /// Called on the main thread when a track finishes or is stopped.
    var stopped: ((CueTrack?, Error?) -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Seconds of audio played since the track started.
    var currentSeconds: Double {
        guard player.isPlaying, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func stop() {
        lock.lock()
        cancellation?.cancel()
        cancellation = nil
        lock.unlock()
        player.stop()
    }

    func play(_ track: CueTrack) throws {
        stop()

        let source = try DiscSource.forTrack(track)
        let range: (start: Int, end: Int)
        do {
            range = try track.sectorRange(discLength: source.length)
        } catch {
            source.close()
            throw error
        }

        let token = CancellationToken()
        lock.lock(); cancellation = token; lock.unlock()

        if !engine.isRunning {
            try engine.start()
        }
        player.stop()
        player.play()

        totalSeconds = Double((range.end - range.start) * 2352) / Double(44100 * 4)

        let player = self.player
        let format = self.format

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            // At most this many one-second buffers are queued ahead of playback
            let ahead = DispatchSemaphore(value: 4)
            let sectorsPerBuffer = 75
            var sector = [UInt8](repeating: 0, count: 2352 * sectorsPerBuffer)
            var current = range.start
            let finished = DispatchGroup()

            do {
                source.stream.position = Int64(range.start) * 2352
                while current < range.end && !token.isCancellationRequested {
                    let count = min(sectorsPerBuffer, range.end - current)
                    let bytes = try source.stream.readFully(&sector, count: count * 2352)
                    if bytes <= 0 { break }
                    let frames = bytes / 4

                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { break }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    let left = buffer.floatChannelData![0]
                    let right = buffer.floatChannelData![1]
                    sector.withUnsafeBytes { raw in
                        let samples = raw.bindMemory(to: Int16.self)
                        for i in 0..<frames {
                            left[i] = Float(Int16(littleEndian: samples[i * 2])) / 32768
                            right[i] = Float(Int16(littleEndian: samples[i * 2 + 1])) / 32768
                        }
                    }

                    while ahead.wait(timeout: .now() + 0.05) == .timedOut {
                        if token.isCancellationRequested { break }
                    }
                    if token.isCancellationRequested { break }

                    finished.enter()
                    player.scheduleBuffer(buffer) {
                        ahead.signal()
                        finished.leave()
                    }
                    current += count
                }

                // Wait for what was queued to finish playing
                while finished.wait(timeout: .now() + 0.05) == .timedOut {
                    if token.isCancellationRequested { break }
                }
            } catch {
                failure = error
            }

            source.close()

            DispatchQueue.main.async {
                guard let self else { return }
                if !token.isCancellationRequested {
                    self.player.stop()
                }
                self.stopped?(track, failure)
            }
        }
    }
}
