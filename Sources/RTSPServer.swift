import Foundation
import Network

/// RTP-Pakete für H.264 (RFC 6184) und AAC (RFC 3640, AAC-hbr) sowie RTCP-Sender-Reports
enum RTP {
    static let maxPayload = 1400
    static let videoPayloadType: UInt8 = 96
    static let audioPayloadType: UInt8 = 97

    /// Nutzdaten eines Bildes: kleine NAL-Units einzeln, große als FU-A-Fragmente
    static func h264Payloads(_ frame: EncodedVideoFrame, parameters: VideoParameters) -> [[UInt8]] {
        var nalUnits: [[UInt8]] = []
        if frame.isKeyframe { nalUnits += [parameters.sps, parameters.pps] }
        nalUnits += frame.slices
        var payloads: [[UInt8]] = []
        for nal in nalUnits where nal.isEmpty == false {
            if nal.count <= maxPayload {
                payloads.append(nal)
                continue
            }
            let indicator = (nal[0] & 0xE0) | 28   // FU-A
            let type = nal[0] & 0x1F
            var offset = 1
            while offset < nal.count {
                let size = min(maxPayload - 2, nal.count - offset)
                var header = type
                if offset == 1 { header |= 0x80 }                      // Start
                if offset + size == nal.count { header |= 0x40 }       // Ende
                var payload: [UInt8] = [indicator, header]
                payload += nal[offset..<(offset + size)]
                payloads.append(payload)
                offset += size
            }
        }
        return payloads
    }

    static func aacPayload(_ frame: EncodedAudioFrame) -> [UInt8] {
        let size = frame.data.count
        // AU-headers-length = 16 Bit, ein AU-Header: 13 Bit Größe + 3 Bit Index
        var payload: [UInt8] = [0x00, 0x10, UInt8((size >> 5) & 0xFF), UInt8((size & 0x1F) << 3)]
        payload += frame.data
        return payload
    }

    static func packet(payloadType: UInt8, marker: Bool, sequence: UInt16, timestamp: UInt32,
                       ssrc: UInt32, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [0x80, (marker ? 0x80 : 0x00) | payloadType]
        packet.appendU16(Int(sequence))
        packet.appendU32(timestamp)
        packet.appendU32(ssrc)
        packet += payload
        return packet
    }

    /// RTP/RTCP über die RTSP-Verbindung: „$“, Kanal, Länge
    static func interleaved(channel: Int, _ packet: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x24, UInt8(channel & 0xFF)]
        out.appendU16(packet.count)
        out += packet
        return out
    }

    /// Sender Report + SDES (CNAME): verknüpft RTP-Zeitstempel mit der Uhrzeit, damit Bild und Ton synchron laufen
    static func senderReport(ssrc: UInt32, ntp: Double, rtpTimestamp: UInt32, packets: Int, octets: Int) -> [UInt8] {
        var report: [UInt8] = [0x80, 200]
        report.appendU16(6)
        report.appendU32(ssrc)
        let seconds = floor(ntp)
        report.appendU32(UInt32(truncatingIfNeeded: Int64(seconds)))
        report.appendU32(UInt32(truncatingIfNeeded: Int64((ntp - seconds) * 4_294_967_296)))
        report.appendU32(rtpTimestamp)
        report.appendU32(UInt32(truncatingIfNeeded: packets))
        report.appendU32(UInt32(truncatingIfNeeded: octets))

        let cname = Array("hdmi-capture".utf8)
        var chunk: [UInt8] = []
        chunk.appendU32(ssrc)
        chunk += [1, UInt8(cname.count)]
        chunk += cname
        chunk.append(0)
        while chunk.count % 4 != 0 { chunk.append(0) }
        var sdes: [UInt8] = [0x81, 202]
        sdes.appendU16(chunk.count / 4)
        sdes += chunk
        return report + sdes
    }
}

/// RTSP-Server (RFC 2326). RTP und RTCP laufen über die RTSP-TCP-Verbindung („interleaved“) –
/// das ist im WLAN robuster als UDP. Anfragen für UDP werden mit 461 beantwortet,
/// worauf VLC und ffmpeg automatisch auf TCP wechseln. Läuft komplett auf `queue`.
final class RTSPServer {
    let videoSSRC = UInt32.random(in: 1...UInt32.max)
    let audioSSRC = UInt32.random(in: 1...UInt32.max)
    private let videoTimestampOffset = UInt32.random(in: 0...UInt32.max)
    private let audioTimestampOffset = UInt32.random(in: 0...UInt32.max)
    private let sessionVersion = Int(Date().timeIntervalSince1970)

    var mediaTimeNow: () -> Double? = { nil }
    var onSessionsChanged: (() -> Void)?
    /// Ab so vielen unbestätigten Bytes gilt ein Zuschauer als zu langsam
    var slowClientBytes = 4_000_000
    /// Darf diese Gegenstelle zugreifen? Abgelehnte Verbindungen werden sofort geschlossen.
    var isAllowed: (NWEndpoint) -> Bool = { _ in true }
    var onRejected: ((NWEndpoint) -> Void)?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let port: UInt16
    private var sessions: [ObjectIdentifier: RTSPSession] = [:]
    private var readyCallback: ((Error?) -> Void)?
    private var timer: DispatchSourceTimer?
    private(set) var videoParameters: VideoParameters?
    private(set) var audioParameters: AudioParameters?

    var playingCount: Int { sessions.values.filter { $0.isPlaying }.count }

    init(port: UInt16, queue: DispatchQueue) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw StreamError.portUnavailable(port) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: endpointPort)
        self.queue = queue
        self.port = port
    }

    func start(ready: @escaping (Error?) -> Void) {
        readyCallback = ready
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reportReady(nil)
            case .failed, .waiting:
                self.reportReady(StreamError.portUnavailable(self.port))
                self.listener.cancel()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendReports(to: nil) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        listener.cancel()
        let open = Array(sessions.values)
        sessions.removeAll()
        open.forEach { $0.close() }
    }

    private func reportReady(_ error: Error?) {
        guard let callback = readyCallback else { return }
        readyCallback = nil
        callback(error)
    }

    /// Schließt bestehende Sitzungen, die nach einer Änderung der Zugriffsliste nicht mehr erlaubt sind
    func closeDisallowed() {
        for session in Array(sessions.values) where isAllowed(session.endpoint) == false {
            session.close()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isAllowed(connection.endpoint) else {
            connection.cancel()
            onRejected?(connection.endpoint)
            return
        }
        let session = RTSPSession(connection: connection, queue: queue, server: self)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.onClose = { [weak self] in
            self?.sessions[id] = nil
            self?.onSessionsChanged?()
        }
        session.onStateChange = { [weak self] in self?.onSessionsChanged?() }
        session.start()
    }

    // MARK: Medien

    func deliverVideo(_ frame: EncodedVideoFrame, parameters: VideoParameters) {
        videoParameters = parameters
        guard sessions.values.contains(where: { $0.isPlaying }) else { return }
        let payloads = RTP.h264Payloads(frame, parameters: parameters)
        let timestamp = videoTimestamp(at: frame.time)
        for session in sessions.values {
            session.sendVideo(payloads, timestamp: timestamp, isKeyframe: frame.isKeyframe)
        }
    }

    func deliverAudio(_ frame: EncodedAudioFrame, parameters: AudioParameters) {
        audioParameters = parameters
        guard sessions.values.contains(where: { $0.isPlaying }) else { return }
        let payload = RTP.aacPayload(frame)
        let timestamp = audioTimestamp(at: frame.time, rate: parameters.sampleRate)
        for session in sessions.values {
            session.sendAudio(payload, timestamp: timestamp)
        }
    }

    private func videoTimestamp(at time: Double) -> UInt32 {
        videoTimestampOffset &+ UInt32(truncatingIfNeeded: Int64((time * 90_000).rounded()))
    }

    private func audioTimestamp(at time: Double, rate: Int) -> UInt32 {
        audioTimestampOffset &+ UInt32(truncatingIfNeeded: Int64((time * Double(rate)).rounded()))
    }

    /// Sender Reports an alle (nil) oder eine Sitzung
    func sendReports(to target: RTSPSession?) {
        guard let time = mediaTimeNow() else { return }
        let ntp = Date().timeIntervalSince1970 + 2_208_988_800
        let video = videoTimestamp(at: time)
        let audio = audioTimestamp(at: time, rate: audioParameters?.sampleRate ?? 48_000)
        let targets = target.map { [$0] } ?? Array(sessions.values)
        for session in targets {
            session.sendReports(ntp: ntp, videoTimestamp: video, audioTimestamp: audio)
        }
    }

    // MARK: SDP

    func sdp() -> String {
        var lines = ["v=0",
                     "o=- \(sessionVersion) 1 IN IP4 0.0.0.0",
                     "s=HDMI Capture",
                     "c=IN IP4 0.0.0.0",
                     "t=0 0",
                     "a=control:*",
                     "a=range:npt=0-",
                     "m=video 0 RTP/AVP \(RTP.videoPayloadType)",
                     "a=rtpmap:\(RTP.videoPayloadType) H264/90000"]
        if let video = videoParameters {
            let sps = Data(video.sps).base64EncodedString()
            let pps = Data(video.pps).base64EncodedString()
            lines.append("a=fmtp:\(RTP.videoPayloadType) packetization-mode=1;profile-level-id=\(video.profileLevelID);sprop-parameter-sets=\(sps),\(pps)")
        } else {
            lines.append("a=fmtp:\(RTP.videoPayloadType) packetization-mode=1")
        }
        lines.append("a=control:trackID=0")
        if let audio = audioParameters {
            lines.append("m=audio 0 RTP/AVP \(RTP.audioPayloadType)")
            lines.append("a=rtpmap:\(RTP.audioPayloadType) MPEG4-GENERIC/\(audio.sampleRate)/\(audio.channels)")
            lines.append("a=fmtp:\(RTP.audioPayloadType) streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=\(hexString(audio.audioSpecificConfig))")
            lines.append("a=control:trackID=1")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

/// Eine RTSP-Verbindung (ein Zuschauer)
final class RTSPSession {
    var onClose: (() -> Void)?
    var onStateChange: (() -> Void)?
    private(set) var isPlaying = false
    var endpoint: NWEndpoint { connection.endpoint }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: RTSPServer?
    private let sessionID = String(format: "%08X", UInt32.random(in: 0...UInt32.max))
    private var buffer: [UInt8] = []
    private var closed = false
    private var pendingBytes = 0
    private var videoChannel: Int?
    private var audioChannel: Int?
    private var waitingForKeyframe = true
    private var videoSequence = UInt16.random(in: 0...UInt16.max)
    private var audioSequence = UInt16.random(in: 0...UInt16.max)
    private var videoPackets = 0
    private var videoOctets = 0
    private var audioPackets = 0
    private var audioOctets = 0

    init(connection: NWConnection, queue: DispatchQueue, server: RTSPServer) {
        self.connection = connection
        self.queue = queue
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard closed == false else { return }
        closed = true
        isPlaying = false
        connection.cancel()
        onClose?()
        onClose = nil
    }

    // MARK: Empfang

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.closed == false else { return }
            if let data, data.isEmpty == false {
                self.buffer.append(contentsOf: data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        while closed == false, let first = buffer.first {
            if first == 0x24 {
                // Interleaved-Daten vom Client (RTCP Receiver Reports) – überspringen
                guard buffer.count >= 4 else { return }
                let length = (Int(buffer[2]) << 8) | Int(buffer[3])
                guard buffer.count >= 4 + length else { return }
                buffer.removeFirst(4 + length)
                continue
            }
            guard let end = findHeaderEnd(buffer) else {
                if buffer.count > 65_536 { close() }
                return
            }
            guard let message = parseMessageHead(buffer[..<end]) else {
                close()
                return
            }
            let bodyLength = Int(message.headers["content-length"] ?? "") ?? 0
            guard buffer.count >= end + 4 + bodyLength else { return }
            buffer.removeFirst(end + 4 + bodyLength)
            let parts = message.startLine.split(separator: " ")
            guard parts.count >= 2 else {
                close()
                return
            }
            handle(method: String(parts[0]).uppercased(), url: String(parts[1]), headers: message.headers)
        }
    }

    private func handle(method: String, url: String, headers: [String: String]) {
        guard let server else { return }
        let cseq = headers["cseq"] ?? "0"
        switch method {
        case "OPTIONS":
            reply(200, cseq: cseq, ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER, SET_PARAMETER"])
        case "DESCRIBE":
            let base = url.hasSuffix("/") ? url : url + "/"
            reply(200, cseq: cseq, ["Content-Base": base, "Content-Type": "application/sdp"], body: server.sdp())
        case "SETUP":
            let transport = headers["transport"] ?? ""
            guard transport.uppercased().contains("RTP/AVP/TCP") else {
                reply(461, cseq: cseq, [:])   // nur TCP – Client wechselt darauf
                return
            }
            let track = url.contains("trackID=1") ? 1 : 0
            var channel = track * 2
            if let range = transport.range(of: "interleaved=") {
                let digits = transport[range.upperBound...].prefix { $0.isNumber }
                if let value = Int(digits) { channel = value }
            }
            if track == 0 { videoChannel = channel } else { audioChannel = channel }
            reply(200, cseq: cseq, ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)",
                                    "Session": "\(sessionID);timeout=60"])
        case "PLAY":
            isPlaying = true
            waitingForKeyframe = true
            reply(200, cseq: cseq, ["Session": sessionID, "Range": "npt=0.000-"])
            onStateChange?()
        case "PAUSE":
            isPlaying = false
            reply(200, cseq: cseq, ["Session": sessionID])
            onStateChange?()
        case "TEARDOWN":
            isPlaying = false
            reply(200, cseq: cseq, ["Session": sessionID]) { [weak self] in self?.close() }
        case "GET_PARAMETER", "SET_PARAMETER":
            reply(200, cseq: cseq, ["Session": sessionID])
        default:
            reply(501, cseq: cseq, [:])
        }
    }

    private func reply(_ status: Int, cseq: String, _ headers: [String: String], body: String = "",
                       then completion: (() -> Void)? = nil) {
        var text = "RTSP/1.0 \(status) \(Self.reason(status))\r\nCSeq: \(cseq)\r\nServer: HDMI Capture\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        let bodyBytes = Array(body.utf8)
        if bodyBytes.isEmpty == false { text += "Content-Length: \(bodyBytes.count)\r\n" }
        text += "\r\n"
        write(Array(text.utf8) + bodyBytes, completion: completion)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 454: return "Session Not Found"
        case 461: return "Unsupported Transport"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }

    // MARK: Senden

    func sendVideo(_ payloads: [[UInt8]], timestamp: UInt32, isKeyframe: Bool) {
        guard isPlaying, let channel = videoChannel, let server, payloads.isEmpty == false else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }
        // Zu langsamer Client: bis zum nächsten Keyframe aussetzen
        if pendingBytes > server.slowClientBytes {
            waitingForKeyframe = true
            return
        }
        let first = videoPackets == 0
        var out: [UInt8] = []
        for (index, payload) in payloads.enumerated() {
            let packet = RTP.packet(payloadType: RTP.videoPayloadType, marker: index == payloads.count - 1,
                                    sequence: videoSequence, timestamp: timestamp, ssrc: server.videoSSRC, payload: payload)
            out += RTP.interleaved(channel: channel, packet)
            videoSequence &+= 1
            videoPackets += 1
            videoOctets += payload.count
        }
        write(out)
        if first { server.sendReports(to: self) }
    }

    func sendAudio(_ payload: [UInt8], timestamp: UInt32) {
        guard isPlaying, waitingForKeyframe == false, let channel = audioChannel, let server else { return }
        let first = audioPackets == 0
        let packet = RTP.packet(payloadType: RTP.audioPayloadType, marker: true, sequence: audioSequence,
                                timestamp: timestamp, ssrc: server.audioSSRC, payload: payload)
        write(RTP.interleaved(channel: channel, packet))
        audioSequence &+= 1
        audioPackets += 1
        audioOctets += payload.count
        if first { server.sendReports(to: self) }
    }

    func sendReports(ntp: Double, videoTimestamp: UInt32, audioTimestamp: UInt32) {
        guard isPlaying, let server else { return }
        var out: [UInt8] = []
        if let channel = videoChannel, videoPackets > 0 {
            out += RTP.interleaved(channel: channel + 1,
                                   RTP.senderReport(ssrc: server.videoSSRC, ntp: ntp, rtpTimestamp: videoTimestamp,
                                                    packets: videoPackets, octets: videoOctets))
        }
        if let channel = audioChannel, audioPackets > 0 {
            out += RTP.interleaved(channel: channel + 1,
                                   RTP.senderReport(ssrc: server.audioSSRC, ntp: ntp, rtpTimestamp: audioTimestamp,
                                                    packets: audioPackets, octets: audioOctets))
        }
        if out.isEmpty == false { write(out) }
    }

    private func write(_ bytes: [UInt8], completion: (() -> Void)? = nil) {
        guard closed == false else { return }
        let count = bytes.count
        pendingBytes += count
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= count
            if error != nil {
                self.close()
                return
            }
            completion?()
        })
    }
}
