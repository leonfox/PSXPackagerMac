import Foundation
import CShine

public enum CDAudioFormat {
    case wav
    case mp3

    /// The extension a format is normally saved with, including the dot.
    public var fileExtension: String {
        switch self {
        case .wav: return ".wav"
        case .mp3: return ".mp3"
        }
    }
}

/// Writes a cue sheet's audio track out as a WAV or an MP3.
///
/// A CD audio track is already 44.1kHz 16-bit stereo PCM, so writing a WAV only wraps the sectors
/// in a header. An MP3 is encoded from those same sectors.
public enum CDAudioExtractor {
    static let sectorSize = 2352
    static let sectorsPerProgressReport = 64

    /// Extracts one audio track to a file.
    /// - Parameter progress: told (bytesRead, totalBytes) every so often.
    public static func extract(_ track: CueTrack, to path: String, format: CDAudioFormat, bitRate: Int = 192,
                               progress: ((Int64, Int64) -> Void)? = nil,
                               cancellation: CancellationToken = CancellationToken()) throws {
        if track.dataType.uppercased() != "AUDIO" {
            throw PSXError.message("Track \(track.number) is not an audio track")
        }

        // Whether the track lives in a .bin, a .chd or a disc inside an EBOOT, it reads the same
        let source = try DiscSource.forTrack(track)
        defer { source.close() }

        let range = try track.sectorRange(discLength: source.length)

        let writer: PCMWriter = format == .mp3
            ? try MP3Writer(path: path, bitRate: bitRate)
            : try WAVWriter(path: path)

        do {
            try write(source, writer, range.start, range.end, progress, cancellation)
            try writer.finish()
        } catch {
            writer.abandon()
            throw error
        }
    }

    private static func write(_ source: DiscSource, _ writer: PCMWriter, _ startSector: Int, _ endSector: Int,
                              _ progress: ((Int64, Int64) -> Void)?, _ cancellation: CancellationToken) throws {
        let total = Int64(endSector - startSector) * Int64(sectorSize)
        source.stream.position = Int64(startSector) * Int64(sectorSize)

        var sector = [UInt8](repeating: 0, count: sectorSize)
        var written: Int64 = 0

        var current = startSector
        while current < endSector {
            if cancellation.isCancellationRequested {
                throw PSXError.aborted("The operation was cancelled")
            }

            // The disc ran out before the cue sheet said it would
            if try source.stream.readFully(&sector, count: sectorSize) != sectorSize { break }

            try writer.write(sector)
            written += Int64(sectorSize)

            if (current - startSector) % sectorsPerProgressReport == 0 {
                progress?(written, total)
            }
            current += 1
        }

        progress?(written, total)
    }
}

protocol PCMWriter {
    func write(_ samples: [UInt8]) throws
    func finish() throws
    func abandon()
}

/// 44.1kHz 16-bit stereo WAV.
final class WAVWriter: PCMWriter {
    private let output: OutputFile
    private var dataBytes: UInt32 = 0

    init(path: String) throws {
        output = try OutputFile(path: path)
        try writeHeader()
    }

    private func writeHeader() throws {
        try output.writeASCII("RIFF")
        try output.writeUInt32(36 &+ dataBytes)
        try output.writeASCII("WAVE")
        try output.writeASCII("fmt ")
        try output.writeUInt32(16)
        try output.writeUInt16(1)            // PCM
        try output.writeUInt16(2)            // channels
        try output.writeUInt32(44100)        // sample rate
        try output.writeUInt32(44100 * 4)    // byte rate
        try output.writeUInt16(4)            // block align
        try output.writeUInt16(16)           // bits per sample
        try output.writeASCII("data")
        try output.writeUInt32(dataBytes)
    }

    func write(_ samples: [UInt8]) throws {
        try output.write(samples)
        dataBytes &+= UInt32(samples.count)
    }

    func finish() throws {
        let end = output.position
        try output.seek(to: 0)
        try writeHeader()
        try output.seek(to: end)
        try output.close()
    }

    func abandon() {
        try? output.close()
        try? FileManager.default.removeItem(atPath: output.path)
    }
}

/// Encodes 44.1kHz 16-bit stereo PCM to MP3 with the Shine encoder.
final class MP3Writer: PCMWriter {
    private let output: OutputFile
    private var encoder: shine_t?
    private let samplesPerPass: Int
    private var pending: [Int16] = []

    init(path: String, bitRate: Int) throws {
        var config = shine_config_t()
        shine_set_config_mpeg_defaults(&config.mpeg)
        config.wave.samplerate = 44100
        config.wave.channels = PCM_STEREO
        config.mpeg.bitr = Int32(bitRate)
        config.mpeg.mode = STEREO

        if shine_check_config(config.wave.samplerate, config.mpeg.bitr) < 0 {
            throw PSXError.message("Unsupported MP3 bit rate \(bitRate)")
        }

        guard let encoder = shine_initialise(&config) else {
            throw PSXError.message("Could not start the MP3 encoder")
        }

        self.encoder = encoder
        samplesPerPass = Int(shine_samples_per_pass(encoder))
        output = try OutputFile(path: path)
    }

    func write(_ samples: [UInt8]) throws {
        var i = 0
        while i + 1 < samples.count {
            pending.append(Int16(bitPattern: UInt16(samples[i]) | UInt16(samples[i + 1]) << 8))
            i += 2
        }
        try encodeFullFrames()
    }

    private func encodeFullFrames() throws {
        guard let encoder else { return }
        let frameSamples = samplesPerPass * 2  // interleaved stereo
        var consumed = 0
        while pending.count - consumed >= frameSamples {
            var written: Int32 = 0
            let data = pending.withUnsafeMutableBufferPointer { buffer in
                shine_encode_buffer_interleaved(encoder, buffer.baseAddress! + consumed, &written)
            }
            if let data, written > 0 {
                try output.write(UnsafeRawBufferPointer(start: data, count: Int(written)))
            }
            consumed += frameSamples
        }
        if consumed > 0 { pending.removeFirst(consumed) }
    }

    func finish() throws {
        guard let encoder else { return }
        // Pad the last partial frame with silence
        let frameSamples = samplesPerPass * 2
        if !pending.isEmpty {
            pending.append(contentsOf: repeatElement(0, count: frameSamples - pending.count % frameSamples))
            try encodeFullFrames()
        }
        var written: Int32 = 0
        if let data = shine_flush(encoder, &written), written > 0 {
            try output.write(UnsafeRawBufferPointer(start: data, count: Int(written)))
        }
        shine_close(encoder)
        self.encoder = nil
        try output.close()
    }

    func abandon() {
        if let encoder { shine_close(encoder) }
        encoder = nil
        try? output.close()
        try? FileManager.default.removeItem(atPath: output.path)
    }
}
