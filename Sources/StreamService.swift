import CoreMedia
import Darwin
import Foundation
import Network

struct StreamAddresses {
    /// IP-Adresse des Macs im lokalen Netz
    let host: String
    let ts: String
    let dash: String
    let rtsp: String

    var summary: String { "MPEG-TS: \(ts)\nMPEG-DASH: \(dash)\nRTSP: \(rtsp)" }
}

enum StreamError: LocalizedError {
    case portUnavailable(UInt16)

    var errorDescription: String? {
        switch self {
        case .portUnavailable(let port): return "Port \(port) ist belegt oder nicht verfügbar"
        }
    }
}

/// Stellt den Stream im lokalen Netz bereit:
/// MPEG-TS über HTTP (`/live.ts`), MPEG-DASH (`/dash/live.mpd`) auf Port 8080 und RTSP auf Port 8554.
/// Der Encoder wird von der Capture-Queue gefüttert; alles andere läuft auf der eigenen Stream-Queue.
final class StreamService {
    static let httpPort: UInt16 = 8080
    static let rtspPort: UInt16 = 8554
    /// dash.js-Version für den Player auf der Infoseite (von cdn.dashjs.org)
    static let dashJSVersion = "5.2.1"

    let encoder: StreamEncoder
    /// Zuschauerzahl hat sich geändert (Aufruf auf der Stream-Queue)
    var onViewers: ((Int) -> Void)?
    /// Verbindung von dieser Adresse abgewiesen (Aufruf auf der Stream-Queue)
    var onRejected: ((String) -> Void)?

    private let queue: DispatchQueue
    private var accessList: NetworkAccessList
    private let tsMuxer = TSMuxer()
    private let dash: DashPackager
    private var http: HTTPServer?
    private var rtsp: RTSPServer?
    private var tsClients: [ObjectIdentifier: TSClient] = [:]
    private var dashViewers: [String: Double] = [:]
    private var waiters: [Waiter] = []
    private var timer: DispatchSourceTimer?
    private var viewerCount = 0
    private var pendingStarts = 0
    private var startError: Error?
    private var startCompletion: ((Result<StreamAddresses, Error>) -> Void)?
    private var stopped = false

    /// Eine HTTP-Antwort, die auf Daten wartet (z. B. das nächste DASH-Segment)
    private struct Waiter {
        let deadline: Double
        let isReady: () -> Bool
        let finish: () -> Void
    }

    private final class TSClient {
        let connection: HTTPConnection
        var waitingForKeyframe = true
        init(connection: HTTPConnection) { self.connection = connection }
    }

    init(clock: CMClock, accessList: NetworkAccessList, settings: StreamSettings) {
        let queue = DispatchQueue(label: "local.hdmicapture.stream", qos: .userInitiated)
        self.queue = queue
        self.accessList = accessList
        dash = DashPackager(settings: settings)
        encoder = StreamEncoder(outputQueue: queue, clock: clock, settings: settings)
        encoder.onVideo = { [weak self] frame, parameters in self?.handleVideo(frame, parameters) }
        encoder.onAudio = { [weak self] frame, parameters in self?.handleAudio(frame, parameters) }
    }

    // MARK: Start / Stopp

    /// Startet HTTP- und RTSP-Server; `completion` kommt auf der Stream-Queue
    func start(completion: @escaping (Result<StreamAddresses, Error>) -> Void) {
        queue.async { [self] in
            startCompletion = completion
            do {
                let http = try HTTPServer(port: Self.httpPort, queue: queue)
                let rtsp = try RTSPServer(port: Self.rtspPort, queue: queue)
                http.onRequest = { [weak self] request, connection in self?.route(request, connection) }
                rtsp.mediaTimeNow = { [weak self] in self?.encoder.mediaTimeNow() }
                rtsp.onSessionsChanged = { [weak self] in self?.updateViewers() }
                rtsp.slowClientBytes = encoder.settings.slowClientBytes
                http.isAllowed = { [weak self] endpoint in self?.accessList.allows(endpoint) ?? false }
                rtsp.isAllowed = { [weak self] endpoint in self?.accessList.allows(endpoint) ?? false }
                http.onRejected = { [weak self] endpoint in self?.rejected(endpoint) }
                rtsp.onRejected = { [weak self] endpoint in self?.rejected(endpoint) }
                self.http = http
                self.rtsp = rtsp
                pendingStarts = 2
                http.start { [weak self] error in self?.serverReady(error) }
                rtsp.start { [weak self] error in self?.serverReady(error) }
            } catch {
                finishStart(error)
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Auf der Capture-Queue aufrufen (dort läuft auch der Encoder)
    func stop() {
        encoder.invalidate()
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            http?.stop()
            rtsp?.stop()
            http = nil
            rtsp = nil
            let open = waiters
            waiters.removeAll()
            open.forEach { $0.finish() }
            tsClients.removeAll()
            dashViewers.removeAll()
            onViewers?(0)
        }
    }

    /// Neue Zugriffsliste übernehmen; Verbindungen von nicht mehr erlaubten Adressen werden getrennt
    func setAccessList(_ list: NetworkAccessList) {
        queue.async { [self] in
            accessList = list
            http?.closeDisallowed()
            rtsp?.closeDisallowed()
            dashViewers = dashViewers.filter { list.allows(address: $0.key) }
            updateViewers()
        }
    }

    private func rejected(_ endpoint: NWEndpoint) {
        var host = "unbekannt"
        if case let .hostPort(address, _) = endpoint { host = "\(address)" }
        debugLog("Zugriff von \(host) abgelehnt (nicht in der Zugriffsliste)")
        onRejected?(host)
    }

    private func serverReady(_ error: Error?) {
        if let error, startError == nil { startError = error }
        pendingStarts -= 1
        if pendingStarts == 0 { finishStart(startError) }
    }

    private func finishStart(_ error: Error?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        if let error {
            completion(.failure(error))
        } else {
            completion(.success(Self.addresses(host: Self.localAddress())))
        }
    }

    // MARK: Medien

    private func handleVideo(_ frame: EncodedVideoFrame, _ parameters: VideoParameters) {
        guard stopped == false else { return }
        if tsClients.isEmpty == false {
            let packets = tsMuxer.muxVideo(frame, parameters: parameters)
            for client in tsClients.values {
                if client.waitingForKeyframe {
                    guard frame.isKeyframe else { continue }
                    client.waitingForKeyframe = false
                }
                send(packets, to: client)
            }
        }
        dash.addVideo(frame, parameters: parameters)
        rtsp?.deliverVideo(frame, parameters: parameters)
        wakeWaiters()
    }

    private func handleAudio(_ frame: EncodedAudioFrame, _ parameters: AudioParameters) {
        guard stopped == false else { return }
        if tsClients.isEmpty == false {
            let packets = tsMuxer.muxAudio(frame, parameters: parameters)
            for client in tsClients.values where client.waitingForKeyframe == false {
                send(packets, to: client)
            }
        }
        dash.addAudio(frame, parameters: parameters)
        rtsp?.deliverAudio(frame, parameters: parameters)
        wakeWaiters()
    }

    private func send(_ packets: [UInt8], to client: TSClient) {
        // Zu langsamer Client (z. B. schwaches WLAN): bis zum nächsten Keyframe aussetzen
        if client.connection.pendingBytes > encoder.settings.slowClientBytes {
            client.waitingForKeyframe = true
            return
        }
        client.connection.write(packets)
    }

    // MARK: HTTP

    private func route(_ request: HTTPRequest, _ connection: HTTPConnection) {
        let headOnly = request.method == "HEAD"
        guard request.method == "GET" || headOnly else {
            connection.respond(status: 405)
            return
        }
        switch request.path {
        case "/", "/index.html":
            connection.respond(status: 200, contentType: "text/html; charset=utf-8",
                               body: Array(statusPage(request).utf8), headOnly: headOnly)
        case "/live.ts":
            if headOnly {
                connection.respond(status: 200, contentType: "video/mp2t", headOnly: true)
                return
            }
            connection.startStream(contentType: "video/mp2t")
            let id = ObjectIdentifier(connection)
            tsClients[id] = TSClient(connection: connection)
            connection.addCloseHandler { [weak self] in
                self?.tsClients[id] = nil
                self?.updateViewers()
            }
            updateViewers()
        case "/dash/live.mpd":
            dashViewers[connection.remoteHost] = now()
            // Kurz warten, bis Bild und Ton bekannt sind – sonst fehlt der Ton im Manifest
            respondWhenReady(connection, timeout: 3, headOnly: headOnly, isReady: { [weak self] in
                self?.dash.isComplete ?? true
            }, content: { [weak self] in
                guard let manifest = self?.dash.manifest() else { return nil }
                return ("application/dash+xml", Array(manifest.utf8))
            })
        default:
            if request.path.hasPrefix("/dash/") {
                serveDashFile(String(request.path.dropFirst(6)), connection, headOnly: headOnly)
            } else {
                connection.respond(status: 404)
            }
        }
    }

    private func serveDashFile(_ name: String, _ connection: HTTPConnection, headOnly: Bool) {
        dashViewers[connection.remoteHost] = now()
        switch name {
        case "video_init.mp4", "audio_init.mp4":
            let isVideo = name.hasPrefix("video")
            respondWhenReady(connection, timeout: 3, headOnly: headOnly, isReady: { [weak self] in
                guard let self else { return true }
                return (isVideo ? self.dash.videoInit : self.dash.audioInit) != nil
            }, content: { [weak self] in
                guard let self, let data = isVideo ? self.dash.videoInit : self.dash.audioInit else { return nil }
                return (isVideo ? "video/mp4" : "audio/mp4", data)
            })
        default:
            guard let segment = DashPackager.parseSegmentName(name) else {
                connection.respond(status: 404)
                return
            }
            let latest = dash.latest(segment.track)
            let available = dash.segment(segment.track, segment.number) != nil
            // Zu alt → 404; bis zu gut 6 s in der Zukunft (Uhren von Mac und Player weichen ab) → warten
            let maxAhead = max(3, Int((6 / dash.settings.segmentDuration).rounded(.up)))
            if available == false && (segment.number <= latest || segment.number > latest + maxAhead) {
                connection.respond(status: 404)
                return
            }
            respondWhenReady(connection, timeout: 8, headOnly: headOnly, isReady: { [weak self] in
                self?.dash.segment(segment.track, segment.number) != nil
            }, content: { [weak self] in
                guard let data = self?.dash.segment(segment.track, segment.number) else { return nil }
                return (segment.track == .video ? "video/mp4" : "audio/mp4", data)
            })
        }
    }

    /// Antwortet sofort, wenn die Daten da sind – sonst sobald sie da sind oder die Zeit abläuft (dann 404)
    private func respondWhenReady(_ connection: HTTPConnection, timeout: Double, headOnly: Bool,
                                  isReady: @escaping () -> Bool,
                                  content: @escaping () -> (String, [UInt8])?) {
        let finish = {
            if let result = content() {
                connection.respond(status: 200, contentType: result.0, body: result.1, headOnly: headOnly)
            } else {
                connection.respond(status: 404)
            }
        }
        if isReady() {
            finish()
        } else {
            waiters.append(Waiter(deadline: now() + timeout, isReady: isReady, finish: finish))
        }
    }

    private func wakeWaiters() {
        guard waiters.isEmpty == false else { return }
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            if waiter.isReady() { waiter.finish() } else { waiters.append(waiter) }
        }
    }

    private func tick() {
        let time = now()
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            if waiter.isReady() || time > waiter.deadline { waiter.finish() } else { waiters.append(waiter) }
        }
        // DASH hat keine dauerhafte Verbindung: Wer in den letzten 10 s etwas abgerufen hat, schaut zu
        dashViewers = dashViewers.filter { time - $0.value < 10 }
        updateViewers()
    }

    private func updateViewers() {
        let count = tsClients.count + (rtsp?.playingCount ?? 0) + dashViewers.count
        guard count != viewerCount else { return }
        viewerCount = count
        onViewers?(count)
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Adressen

    static func addresses(host: String) -> StreamAddresses {
        StreamAddresses(host: host,
                        ts: "http://\(host):\(httpPort)/live.ts",
                        dash: "http://\(host):\(httpPort)/dash/live.mpd",
                        rtsp: "rtsp://\(host):\(rtspPort)/live")
    }

    /// IPv4-Adresse im lokalen Netz, bevorzugt WLAN/Ethernet (en0, en1 …)
    static func localAddress() -> String {
        var candidates: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "localhost" }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            candidates.append((name, ip))
        }
        let usable = candidates.filter { $0.address.hasPrefix("169.254.") == false }
        let best = usable.first { $0.name == "en0" }
            ?? usable.first { $0.name.hasPrefix("en") }
            ?? usable.first
            ?? candidates.first
        return best?.address ?? "localhost"
    }

    // MARK: Infoseite

    private func statusPage(_ request: HTTPRequest) -> String {
        var host = request.headers["host"] ?? Self.localAddress()
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[...end])
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        let addresses = Self.addresses(host: host)
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func vlcLink(_ url: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
            return "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
        }
        var rows = ""
        for (name, url) in [("MPEG-TS", addresses.ts), ("MPEG-DASH", addresses.dash), ("RTSP", addresses.rtsp)] {
            rows += "<tr><th>\(name)</th><td><code>\(escape(url))</code></td>"
            rows += "<td><a href=\"\(escape(vlcLink(url)))\">In VLC öffnen</a></td></tr>\n"
        }
        return """
        <!doctype html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>HDMI Capture</title>
        <style>
        body { font: 16px -apple-system, system-ui, sans-serif; margin: 1.5em auto; max-width: 60em; padding: 0 16px; background: #111; color: #eee; }
        h1 { font-size: 1.4em; margin: 0 0 .6em; }
        h2 { font-size: 1.1em; margin: 1.8em 0 .4em; }
        .player { position: relative; background: #000; border-radius: 8px; overflow: hidden; aspect-ratio: 16 / 9; }
        video { width: 100%; height: 100%; display: block; background: #000; }
        #unmute { position: absolute; top: 12px; right: 12px; font: inherit; font-size: 14px; padding: .45em .9em; border: 0; border-radius: 6px; background: rgba(255,255,255,.88); color: #000; cursor: pointer; }
        #stats { font-variant-numeric: tabular-nums; color: #9c9; margin: .6em 0 0; min-height: 1.4em; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: .6em .5em; border-bottom: 1px solid #333; vertical-align: top; }
        code { word-break: break-all; }
        a { color: #6cf; white-space: nowrap; }
        p { color: #aaa; }
        </style>
        </head>
        <body>
        <h1>HDMI Capture</h1>
        <div class="player">
        <video id="video" controls playsinline autoplay muted></video>
        <button id="unmute" type="button">Ton einschalten</button>
        </div>
        <p id="stats">Lade dash.js …</p>
        <h2>Adressen für VLC und andere Player</h2>
        <p>In VLC: <b>Netzwerk → Netzwerk-Stream öffnen</b> und eine der Adressen eingeben.</p>
        <table>
        \(rows)</table>
        <p>MPEG-TS hat die kürzeste Verzögerung. RTSP läuft über TCP. Der Player oben nutzt MPEG-DASH mit
        dash.js \(Self.dashJSVersion); dafür braucht dieses Gerät Internetzugang.</p>
        <script>
        (function () {
          var video = document.getElementById('video');
          var stats = document.getElementById('stats');
          var unmute = document.getElementById('unmute');
          var sources = [
            'https://cdn.dashjs.org/v\(Self.dashJSVersion)/modern/umd/dash.all.min.js',
            'https://cdn.dashjs.org/v\(Self.dashJSVersion)/legacy/umd/dash.all.min.js'
          ];
          function seconds(value) { return value.toFixed(1).replace('.', ',') + ' s'; }
          function load(index) {
            if (index >= sources.length) {
              stats.textContent = 'dash.js konnte nicht geladen werden – dieses Gerät braucht Internetzugang. Alternativ eine der Adressen unten in VLC öffnen.';
              return;
            }
            var script = document.createElement('script');
            script.src = sources[index];
            script.onload = start;
            script.onerror = function () { load(index + 1); };
            document.head.appendChild(script);
          }
          function start() {
            var player = dashjs.MediaPlayer().create();
            try {
              // Latenzziel kommt aus dem MPD (ServiceDescription); bei Rückstand leicht schneller abspielen
              player.updateSettings({ streaming: { liveCatchup: { enabled: true } } });
            } catch (e) {}
            player.on(dashjs.MediaPlayer.events.ERROR, function (event) {
              var error = event && event.error;
              stats.textContent = 'Fehler: ' + (error && error.message ? error.message : 'unbekannt');
            });
            player.initialize(video, 'dash/live.mpd', true);
            setInterval(function () {
              var parts = [];
              try {
                var latency = player.getCurrentLiveLatency();
                if (latency > 0) { parts.push('Verzögerung ' + seconds(latency)); }
              } catch (e) {}
              try {
                var buffer = player.getBufferLength('video');
                if (buffer >= 0) { parts.push('Puffer ' + seconds(buffer)); }
              } catch (e) {}
              if (video.videoWidth) { parts.push(video.videoWidth + '×' + video.videoHeight); }
              if (parts.length) { stats.textContent = parts.join(' · '); }
            }, 500);
          }
          unmute.addEventListener('click', function () {
            video.muted = false;
            video.play();
            unmute.style.display = 'none';
          });
          load(0);
        })();
        </script>
        </body>
        </html>
        """
    }
}
