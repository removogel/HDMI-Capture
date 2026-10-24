import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    /// Schlüssel klein geschrieben
    let headers: [String: String]
}

/// Kleiner HTTP/1.1-Server auf Basis von Network.framework (Keep-Alive, keine Request-Bodies).
/// Läuft komplett auf `queue`.
final class HTTPServer {
    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    /// Darf diese Gegenstelle zugreifen? Abgelehnte Verbindungen werden sofort geschlossen.
    var isAllowed: (NWEndpoint) -> Bool = { _ in true }
    var onRejected: ((NWEndpoint) -> Void)?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let port: UInt16
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var readyCallback: ((Error?) -> Void)?

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
    }

    func stop() {
        listener.cancel()
        let open = Array(connections.values)
        connections.removeAll()
        open.forEach { $0.close() }
    }

    private func reportReady(_ error: Error?) {
        guard let callback = readyCallback else { return }
        readyCallback = nil
        callback(error)
    }

    /// Schließt bestehende Verbindungen, die nach einer Änderung der Zugriffsliste nicht mehr erlaubt sind
    func closeDisallowed() {
        for connection in Array(connections.values) where isAllowed(connection.endpoint) == false {
            connection.close()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard isAllowed(nwConnection.endpoint) else {
            nwConnection.cancel()
            onRejected?(nwConnection.endpoint)
            return
        }
        let connection = HTTPConnection(connection: nwConnection, queue: queue)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.addCloseHandler { [weak self] in self?.connections[id] = nil }
        connection.onRequest = { [weak self, weak connection] request in
            guard let self, let connection else { return }
            self.onRequest?(request, connection)
        }
        connection.start()
    }
}

/// Eine HTTP-Verbindung. Anfragen werden nacheinander beantwortet; eine Antwort darf auf sich warten lassen
/// (z. B. bis das nächste DASH-Segment fertig ist). Mit `startStream` wird daraus ein endloser Datenstrom.
final class HTTPConnection {
    let endpoint: NWEndpoint
    let remoteHost: String
    var onRequest: ((HTTPRequest) -> Void)?
    private(set) var isClosed = false
    /// Gesendete, aber noch nicht vom Netzwerk übernommene Bytes – Maß für langsame Clients
    private(set) var pendingBytes = 0

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer: [UInt8] = []
    private var busy = false
    private var keepAlive = true
    private var streaming = false
    private var closeHandlers: [() -> Void] = []

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        endpoint = connection.endpoint
        if case let .hostPort(host, _) = connection.endpoint {
            remoteHost = "\(host)"
        } else {
            remoteHost = "unbekannt"
        }
    }

    func addCloseHandler(_ handler: @escaping () -> Void) {
        closeHandlers.append(handler)
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
        guard isClosed == false else { return }
        isClosed = true
        connection.cancel()
        let handlers = closeHandlers
        closeHandlers.removeAll()
        handlers.forEach { $0() }
    }

    // MARK: Anfragen

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.isClosed == false else { return }
            if let data, data.isEmpty == false, self.streaming == false {
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
        while busy == false, streaming == false, isClosed == false {
            guard let end = findHeaderEnd(buffer) else {
                if buffer.count > 65_536 { close() }
                return
            }
            let head = buffer[..<end]
            guard let message = parseMessageHead(head) else {
                close()
                return
            }
            buffer.removeFirst(end + 4)
            let parts = message.startLine.split(separator: " ")
            guard parts.count >= 3 else {
                close()
                return
            }
            let connectionHeader = message.headers["connection"]?.lowercased() ?? ""
            keepAlive = parts[2] == "HTTP/1.1" ? connectionHeader.contains("close") == false
                                               : connectionHeader.contains("keep-alive")
            var path = String(parts[1])
            if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
            busy = true
            onRequest?(HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: message.headers))
        }
    }

    // MARK: Antworten

    func respond(status: Int, contentType: String? = nil, body: [UInt8] = [], headOnly: Bool = false) {
        guard isClosed == false else { return }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nServer: HDMI Capture\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        var bytes = Array(head.utf8)
        if headOnly == false { bytes += body }
        let closeAfter = keepAlive == false
        write(bytes) { [weak self] in
            if closeAfter { self?.close() }
        }
        busy = false
        if closeAfter == false { processBuffer() }
    }

    /// Antwortkopf ohne Länge senden; danach werden Daten mit `write` nachgeschoben, bis der Client trennt
    func startStream(contentType: String) {
        guard isClosed == false else { return }
        streaming = true
        busy = false
        buffer.removeAll()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\n"
            + "Access-Control-Allow-Origin: *\r\nServer: HDMI Capture\r\nConnection: close\r\n\r\n"
        write(Array(head.utf8))
    }

    func write(_ bytes: [UInt8], completion: (() -> Void)? = nil) {
        guard isClosed == false else { return }
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

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }
}
