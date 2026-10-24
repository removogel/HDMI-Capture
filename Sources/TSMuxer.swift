import Foundation

/// Verpackt H.264 oder HEVC und AAC in einen MPEG-2-Transport-Stream (188-Byte-Pakete).
/// Vor jedem Keyframe stehen PAT und PMT, damit neue Zuschauer dort einsteigen können.
final class TSMuxer {
    private let pmtPID = 0x1000
    private let videoPID = 0x0100
    private let audioPID = 0x0101
    /// Versatz, damit PTS und PCR nie negativ werden
    private let timeOffset = 1.0
    /// PCR läuft dem Bild etwas voraus, damit der Decoder Puffer hat
    private let pcrLead = 0.3
    private var continuity: [Int: UInt8] = [:]

    func muxVideo(_ frame: EncodedVideoFrame, parameters: VideoParameters) -> [UInt8] {
        var out: [UInt8] = []
        if frame.isKeyframe {
            out += psiPacket(pid: 0, section: patSection())
            out += psiPacket(pid: pmtPID, section: pmtSection(parameters.codec))
        }
        // Annex B: Access Unit Delimiter, bei Keyframes die Parametersätze (HEVC: VPS/SPS/PPS), dann die Slices
        var elementary: [UInt8] = parameters.codec == .h264 ? [0, 0, 0, 1, 0x09, 0xF0] : [0, 0, 0, 1, 0x46, 0x01, 0x50]
        if frame.isKeyframe {
            for unit in parameters.parameterSets { elementary += [0, 0, 0, 1] + unit }
        }
        for nal in frame.slices {
            elementary += [0, 0, 0, 1]
            elementary += nal
        }
        let pts = ticks(frame.time)
        let pes = pesPacket(streamID: 0xE0, pts: pts, payload: elementary, bounded: false)
        let pcr = max(0, pts - Int64(pcrLead * 90_000))
        out += packetize(pid: videoPID, data: pes, pcr: pcr, randomAccess: frame.isKeyframe)
        return out
    }

    func muxAudio(_ frame: EncodedAudioFrame, parameters: AudioParameters) -> [UInt8] {
        let payload = adtsHeader(frameLength: frame.data.count + 7, parameters) + frame.data
        let pes = pesPacket(streamID: 0xC0, pts: ticks(frame.time), payload: payload, bounded: true)
        return packetize(pid: audioPID, data: pes, pcr: nil, randomAccess: false)
    }

    // MARK: Zeit

    private func ticks(_ time: Double) -> Int64 {
        Int64(((time + timeOffset) * 90_000).rounded()) & 0x1_FFFF_FFFF
    }

    // MARK: PSI

    private func patSection() -> [UInt8] {
        withCRC([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                 0x00, 0x01, 0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)])
    }

    private func pmtSection(_ codec: VideoCodec) -> [UInt8] {
        let videoType: UInt8 = codec == .h264 ? 0x1B : 0x24   // H.264 bzw. HEVC
        // Versionsnummer wechselt mit dem Codec, damit Empfänger die neue PMT übernehmen
        let version: UInt8 = codec == .h264 ? 0xC1 : 0xC3
        return withCRC([0x02, 0xB0, 0x17, 0x00, 0x01, version, 0x00, 0x00,
                 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00,
                 videoType, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00,
                 0x0F, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00])  // AAC (ADTS)
    }

    private func withCRC(_ section: [UInt8]) -> [UInt8] {
        var result = section
        result.appendU32(CRC32MPEG.checksum(section))
        return result
    }

    private func psiPacket(pid: Int, section: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | nextContinuity(pid), 0x00]
        packet += section
        packet += [UInt8](repeating: 0xFF, count: 188 - packet.count)
        return packet
    }

    // MARK: PES

    private func pesPacket(streamID: UInt8, pts: Int64, payload: [UInt8], bounded: Bool) -> [UInt8] {
        var pes: [UInt8] = [0x00, 0x00, 0x01, streamID]
        let length = 3 + 5 + payload.count
        pes.appendU16(bounded && length <= 0xFFFF ? length : 0)
        pes += [0x80, 0x80, 0x05]   // nur PTS
        pes += [0x21 | UInt8((pts >> 29) & 0x0E),
                UInt8((pts >> 22) & 0xFF),
                UInt8(((pts >> 14) & 0xFE) | 0x01),
                UInt8((pts >> 7) & 0xFF),
                UInt8(((pts << 1) & 0xFE) | 0x01)]
        pes += payload
        return pes
    }

    private func adtsHeader(frameLength: Int, _ parameters: AudioParameters) -> [UInt8] {
        let profile = 1   // AAC-LC (Objekttyp 2) minus 1
        let frequency = parameters.frequencyIndex
        let channels = parameters.channels
        return [0xFF, 0xF1,
                UInt8((profile << 6) | (frequency << 2) | (channels >> 2)),
                UInt8(((channels & 0x03) << 6) | ((frameLength >> 11) & 0x03)),
                UInt8((frameLength >> 3) & 0xFF),
                UInt8(((frameLength & 0x07) << 5) | 0x1F),
                0xFC]
    }

    // MARK: Transport-Pakete

    private func packetize(pid: Int, data: [UInt8], pcr: Int64?, randomAccess: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((data.count / 184 + 2) * 188)
        var offset = 0
        var first = true
        while offset < data.count {
            // Adaptation Field: Flags (+ PCR) im ersten Paket, Stopfbytes im letzten
            var adaptation: [UInt8] = []
            var hasAdaptation = false
            if first, pcr != nil || randomAccess {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                if pcr != nil { flags |= 0x10 }
                adaptation.append(flags)
                if let pcr { adaptation += Self.pcrField(pcr) }
                hasAdaptation = true
            }
            let adaptationSize = hasAdaptation ? 1 + adaptation.count : 0
            let payloadSize = min(184 - adaptationSize, data.count - offset)
            let gap = 184 - adaptationSize - payloadSize
            if gap > 0 {
                if hasAdaptation {
                    adaptation += [UInt8](repeating: 0xFF, count: gap)
                } else if gap == 1 {
                    hasAdaptation = true                // nur das Längenbyte (Länge 0)
                } else {
                    adaptation = [0x00] + [UInt8](repeating: 0xFF, count: gap - 2)
                    hasAdaptation = true
                }
            }
            out.append(0x47)
            out.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            out.append(UInt8(pid & 0xFF))
            out.append((hasAdaptation ? 0x30 : 0x10) | nextContinuity(pid))
            if hasAdaptation {
                out.append(UInt8(adaptation.count))
                out += adaptation
            }
            out += data[offset..<(offset + payloadSize)]
            offset += payloadSize
            first = false
        }
        return out
    }

    private static func pcrField(_ base: Int64) -> [UInt8] {
        [UInt8((base >> 25) & 0xFF),
         UInt8((base >> 17) & 0xFF),
         UInt8((base >> 9) & 0xFF),
         UInt8((base >> 1) & 0xFF),
         UInt8(((base & 0x01) << 7) | 0x7E),
         0x00]
    }

    private func nextContinuity(_ pid: Int) -> UInt8 {
        let value = continuity[pid, default: 0]
        continuity[pid] = (value + 1) & 0x0F
        return value
    }
}
