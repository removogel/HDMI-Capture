import Foundation

/// Bausteine für fragmentiertes MP4 (CMAF): Init-Segmente (H.264, HEVC, AAC) und Media-Segmente (moof + mdat)
enum MP4 {
    struct Sample {
        let data: [UInt8]
        let duration: UInt32
        let flags: UInt32
    }

    /// Sample-Flags: Keyframe (hängt von nichts ab) bzw. abhängiges Bild
    static let syncSampleFlags: UInt32 = 0x0200_0000
    static let nonSyncSampleFlags: UInt32 = 0x0101_0000

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendU32(UInt32(8 + payload.count))
        out.appendASCII(type)
        out += payload
        return out
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: Int = 0, _ payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [version]
        body.appendU24(flags)
        return box(type, body + payload)
    }

    private static let matrix: [UInt8] = {
        var bytes: [UInt8] = []
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { bytes.appendU32(value) }
        return bytes
    }()

    // MARK: Init-Segment

    static func videoInit(_ parameters: VideoParameters, trackID: Int) -> [UInt8] {
        initSegment(trackID: trackID, timescale: 90_000, isAudio: false,
                    width: parameters.width, height: parameters.height,
                    sampleEntry: parameters.codec == .h264 ? avc1(parameters) : hvc1(parameters))
    }

    static func audioInit(_ parameters: AudioParameters, trackID: Int, bitRate: Int) -> [UInt8] {
        initSegment(trackID: trackID, timescale: parameters.sampleRate, isAudio: true,
                    width: 0, height: 0, sampleEntry: mp4a(parameters, bitRate: bitRate))
    }

    private static func initSegment(trackID: Int, timescale: Int, isAudio: Bool,
                                    width: Int, height: Int, sampleEntry: [UInt8]) -> [UInt8] {
        var ftyp: [UInt8] = []
        ftyp.appendASCII("iso6")
        ftyp.appendU32(0)
        for brand in ["iso6", "cmfc", "dash"] { ftyp.appendASCII(brand) }

        var mvhd: [UInt8] = []
        mvhd.appendU32(0)                 // creation_time
        mvhd.appendU32(0)                 // modification_time
        mvhd.appendU32(1000)              // timescale
        mvhd.appendU32(0)                 // duration
        mvhd.appendU32(0x0001_0000)       // rate 1.0
        mvhd.appendU16(0x0100)            // volume 1.0
        mvhd += [UInt8](repeating: 0, count: 10)
        mvhd += matrix
        mvhd += [UInt8](repeating: 0, count: 24)
        mvhd.appendU32(UInt32(trackID + 1))   // next_track_ID

        var tkhd: [UInt8] = []
        tkhd.appendU32(0)
        tkhd.appendU32(0)
        tkhd.appendU32(UInt32(trackID))
        tkhd.appendU32(0)
        tkhd.appendU32(0)                 // duration
        tkhd += [UInt8](repeating: 0, count: 8)
        tkhd.appendU16(0)                 // layer
        tkhd.appendU16(0)                 // alternate_group
        tkhd.appendU16(isAudio ? 0x0100 : 0)
        tkhd.appendU16(0)
        tkhd += matrix
        tkhd.appendU32(UInt32(width) << 16)
        tkhd.appendU32(UInt32(height) << 16)

        var mdhd: [UInt8] = []
        mdhd.appendU32(0)
        mdhd.appendU32(0)
        mdhd.appendU32(UInt32(timescale))
        mdhd.appendU32(0)
        mdhd.appendU16(0x55C4)            // Sprache „und“
        mdhd.appendU16(0)

        var hdlr: [UInt8] = []
        hdlr.appendU32(0)
        hdlr.appendASCII(isAudio ? "soun" : "vide")
        hdlr += [UInt8](repeating: 0, count: 12)
        hdlr.appendASCII(isAudio ? "SoundHandler" : "VideoHandler")
        hdlr.append(0)

        let mediaHeader = isAudio
            ? fullBox("smhd", [0, 0, 0, 0])
            : fullBox("vmhd", flags: 1, [UInt8](repeating: 0, count: 8))
        let noEntries: [UInt8] = [0, 0, 0, 0]
        var dref: [UInt8] = [0, 0, 0, 1]
        dref += fullBox("url ", flags: 1, [])
        let dinf = box("dinf", fullBox("dref", dref))
        var stsd: [UInt8] = [0, 0, 0, 1]
        stsd += sampleEntry
        var stblBody = fullBox("stsd", stsd)
        stblBody += fullBox("stts", noEntries)
        stblBody += fullBox("stsc", noEntries)
        stblBody += fullBox("stsz", noEntries + noEntries)
        stblBody += fullBox("stco", noEntries)
        let stbl = box("stbl", stblBody)
        let minf = box("minf", mediaHeader + dinf + stbl)
        let mdia = box("mdia", fullBox("mdhd", mdhd) + fullBox("hdlr", hdlr) + minf)
        let trak = box("trak", fullBox("tkhd", flags: 3, tkhd) + mdia)

        var trex: [UInt8] = []
        trex.appendU32(UInt32(trackID))
        trex.appendU32(1)                 // default_sample_description_index
        trex.appendU32(0)
        trex.appendU32(0)
        trex.appendU32(0)
        let mvex = box("mvex", fullBox("trex", trex))

        return box("ftyp", ftyp) + box("moov", fullBox("mvhd", mvhd) + trak + mvex)
    }

    /// VisualSampleEntry-Kopf (ISO/IEC 14496-12) ohne Konfigurations-Box
    private static func visualSampleEntryHead(_ parameters: VideoParameters) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 6)
        entry.appendU16(1)                // data_reference_index
        entry += [UInt8](repeating: 0, count: 16)
        entry.appendU16(parameters.width)
        entry.appendU16(parameters.height)
        entry.appendU32(0x0048_0000)      // 72 dpi
        entry.appendU32(0x0048_0000)
        entry.appendU32(0)
        entry.appendU16(1)                // frame_count
        entry += [UInt8](repeating: 0, count: 32)
        entry.appendU16(0x0018)           // depth
        entry.appendU16(0xFFFF)
        return entry
    }

    private static func avc1(_ parameters: VideoParameters) -> [UInt8] {
        var entry = visualSampleEntryHead(parameters)
        let sps = parameters.sps
        let pps = parameters.pps
        let profile: [UInt8] = sps.count >= 4 ? Array(sps[1...3]) : [0x64, 0x00, 0x28]
        var avcC: [UInt8] = [1]
        avcC += profile
        avcC += [0xFF, 0xE1]              // 4-Byte-Längen, ein SPS
        avcC.appendU16(sps.count)
        avcC += sps
        avcC.append(1)                    // ein PPS
        avcC.appendU16(pps.count)
        avcC += pps
        if sps.count > 1, [100, 110, 122, 144].contains(Int(sps[1])) {
            avcC += [0xFD, 0xF8, 0xF8, 0x00]  // 4:2:0, 8 Bit, keine SPS-Erweiterungen
        }
        entry += box("avcC", avcC)
        return box("avc1", entry)
    }

    /// HEVC mit Parametersätzen nur in der hvcC (nicht im Bild) – „hvc1“, wie Apple es für HLS verlangt
    private static func hvc1(_ parameters: VideoParameters) -> [UInt8] {
        var entry = visualSampleEntryHead(parameters)
        entry += box("hvcC", parameters.hvcC)
        return box("hvc1", entry)
    }

    private static func mp4a(_ parameters: AudioParameters, bitRate: Int) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 6)
        entry.appendU16(1)
        entry += [UInt8](repeating: 0, count: 8)
        entry.appendU16(parameters.channels)
        entry.appendU16(16)               // samplesize
        entry.appendU16(0)
        entry.appendU16(0)
        entry.appendU32(UInt32(parameters.sampleRate) << 16)

        let config = parameters.audioSpecificConfig
        var decoderConfig: [UInt8] = [0x40, 0x15, 0x00, 0x00, 0x00]   // MPEG-4 Audio, Audiostream
        decoderConfig.appendU32(UInt32(bitRate))
        decoderConfig.appendU32(UInt32(bitRate))
        decoderConfig += [0x05, UInt8(config.count)]
        decoderConfig += config
        var esBody: [UInt8] = [0x00, 0x01, 0x00]           // ES_ID 1, keine Flags
        esBody += [0x04, UInt8(decoderConfig.count)]
        esBody += decoderConfig
        esBody += [0x06, 0x01, 0x02]                       // SLConfig
        var esds: [UInt8] = [0x03, UInt8(esBody.count)]
        esds += esBody
        entry += fullBox("esds", esds)
        return box("mp4a", entry)
    }

    // MARK: Media-Segment

    static func mediaSegment(sequence: Int, trackID: Int, baseTime: UInt64, samples: [Sample]) -> [UInt8] {
        func moof(dataOffset: Int) -> [UInt8] {
            var mfhd: [UInt8] = []
            mfhd.appendU32(UInt32(truncatingIfNeeded: sequence))
            var tfhd: [UInt8] = []
            tfhd.appendU32(UInt32(trackID))
            var tfdt: [UInt8] = []
            tfdt.appendU64(baseTime)
            var trun: [UInt8] = []
            trun.appendU32(UInt32(samples.count))
            trun.appendU32(UInt32(truncatingIfNeeded: dataOffset))
            for sample in samples {
                trun.appendU32(sample.duration)
                trun.appendU32(UInt32(sample.data.count))
                trun.appendU32(sample.flags)
            }
            let traf = box("traf",
                           fullBox("tfhd", flags: 0x02_0000, tfhd)        // default-base-is-moof
                           + fullBox("tfdt", version: 1, tfdt)
                           + fullBox("trun", flags: 0x00_0701, trun))     // Offset, Dauer, Größe, Flags
            return box("moof", fullBox("mfhd", mfhd) + traf)
        }
        let moofSize = moof(dataOffset: 0).count
        var out = moof(dataOffset: moofSize + 8)
        let payloadSize = samples.reduce(0) { $0 + $1.data.count }
        out.appendU32(UInt32(8 + payloadSize))
        out.appendASCII("mdat")
        for sample in samples { out += sample.data }
        return out
    }
}
