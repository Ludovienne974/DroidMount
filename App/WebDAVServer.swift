import Foundation
import Network

// MARK: - Minimal WebDAV-capable HTTP server (Network framework)

struct WebDAVRequest {
    var method: String
    var uri: String          // percent-encoded, includes possible ?query
    var headers: [String: String]   // keys lowercased
    var body: Data

    /// Decoded path without query string
    var path: String {
        let raw = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        return Self.percentDecode(raw)
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

struct WebDAVResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data? = nil
    /// Optional: stream this local file instead of sending `body`
    var fileURL: URL? = nil
    var fileOffset: Int64 = 0
    var fileLength: Int64 = 0

    static func status(_ code: Int, headers: [(String, String)] = [], body: Data? = nil) -> WebDAVResponse {
        WebDAVResponse(status: code, headers: headers, body: body)
    }
}

enum HTTPStatus {
    static func phrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 502: return "Bad Gateway"
        default:  return "Error"
        }
    }
}

final class WebDAVConnectionState: @unchecked Sendable {
    var buffer = Data()
    /// While streaming a large PUT (Content-Length) in progress → temp file
    var streamingHead: (request: WebDAVRequest, tempFile: URL, handle: FileHandle, remaining: Int64)?
    /// Decoder for chunked requests (Finder's PUT) — the pending request is stored
    var chunkedWriter: ChunkedWriter?
    var chunkedRequest: WebDAVRequest?
    var closed = false
    var sent100Continue = false
}

final class WebDAVServer: @unchecked Sendable {

    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "droidmount.webdav.server")
    /// NWConnection isn't Hashable on all SDKs: use object identity as key
    private var connections: [ObjectIdentifier: WebDAVConnectionState] = [:]
    private let tmpBase: URL

    /// The request handler (called off the main thread)
    var onRequest: (@Sendable (WebDAVRequest) async -> WebDAVResponse)?

    private static let streamThreshold = 8 * 1024 * 1024   // bodies above → temp file streaming

    init(port: UInt16) {
        self.port = port
        tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMountWebDAV", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("[DroidMount] listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let tmp = tmpBase
        Task {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func accept(_ connection: NWConnection) {
        let state = WebDAVConnectionState()
        connections[ObjectIdentifier(connection)] = state

        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.readNext(connection)
            case .failed, .cancelled:
                self?.cleanup(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func cleanup(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)]?.chunkedWriter?.close()
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: - Read loop
    // All connection handlers run on the serial `queue`: direct access to
    // `connections` and each state is safe. Requests are never pipelined:
    // we only re-arm `receive` after the previous response was fully sent.

    private func readNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let state = self.connections[ObjectIdentifier(connection)], !state.closed else { return }
            if let data = data, !data.isEmpty {
                self.ingest(data, state: state)
            } else if isComplete || error != nil {
                self.cleanup(connection)
                return
            }
            self.drain(connection)
        }
    }

    private func ingest(_ data: Data, state: WebDAVConnectionState) {
        if let writer = state.chunkedWriter {
            // Chunked body in progress: decode the arriving bytes straight away
            let leftover = writer.feed(data)
            if !leftover.isEmpty {
                state.buffer.append(leftover)
            }
        } else if let streaming = state.streamingHead {
            // Large PUT (Content-Length): append arriving bytes straight to the temp file
            let toWrite = min(Int64(data.count), streaming.remaining)
            if toWrite > 0 {
                try? streaming.handle.write(contentsOf: data.prefix(Int(toWrite)))
            }
            state.streamingHead?.remaining = streaming.remaining - toWrite
            if toWrite < Int64(data.count) {
                state.buffer.append(data.suffix(data.count - Int(toWrite)))
            }
        } else {
            state.buffer.append(data)
        }
    }

    private func drain(_ connection: NWConnection) {
        guard let state = connections[ObjectIdentifier(connection)], !state.closed else { return }
        var request: WebDAVRequest?

        // 0. Chunked body in progress (Finder's PUT)? Finished?
        if let writer = state.chunkedWriter {
            if writer.finished {
                var req = state.chunkedRequest!
                state.chunkedRequest = nil
                state.chunkedWriter = nil
                req.body = Data()
                req.headers["x-droidmount-temp-file"] = writer.tempFile.path
                state.sent100Continue = false
                request = req
            } else {
                readNext(connection)   // wait for more chunk data
                return
            }
        }

        // 1. Streaming PUT in progress?
        if let streaming = state.streamingHead {
            if streaming.remaining <= 0 {
                streaming.handle.closeFile()
                var req = streaming.request
                req.body = Data()
                req.headers["x-droidmount-temp-file"] = streaming.tempFile.path
                state.streamingHead = nil
                request = req
            } else {
                readNext(connection)   // wait for more data
                return
            }
        }

        // 2. Try to parse a complete request from the buffer
        if let req = request {
            handle(connection, req)
            return
        }

        guard let headRange = state.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            readNext(connection)
            return
        }

        let headData = state.buffer.subdata(in: state.buffer.startIndex..<headRange.lowerBound)
        guard let headText = String(data: headData, encoding: .utf8) else {
            cleanup(connection)
            return
        }

        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            readNext(connection)
            return
        }
        let reqParts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard reqParts.count >= 3 else {
            cleanup(connection)
            return
        }

        var headers: [String: String] = [:]
        lines.removeFirst()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let isChunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
        let bodyStart = headRange.upperBound
        let bodyAvailable = state.buffer.distance(from: bodyStart, to: state.buffer.endIndex)

        // Finder webdavfs : acknowledge Expect: 100-continue before reading the body
        if let expect = headers["expect"], expect.lowercased().contains("100-continue"),
           (contentLength > 0 || isChunked), !state.sent100Continue {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            state.sent100Continue = true
        }

        var req = WebDAVRequest(method: reqParts[0], uri: reqParts[1], headers: headers, body: Data())

        if isChunked {
            // Chunked body (no Content-Length) → decoded incrementally in a temp file
            let tempFile = tmpBase.appendingPathComponent("chunked-\(UUID().uuidString)")
            let writer = ChunkedWriter(tempFile: tempFile)
            state.chunkedWriter = writer
            state.chunkedRequest = req
            if bodyAvailable > 0 {
                let bodyBytes = state.buffer.subdata(in: bodyStart..<state.buffer.endIndex)
                state.buffer.removeSubrange(bodyStart..<state.buffer.endIndex)
                let leftover = writer.feed(bodyBytes)
                if !leftover.isEmpty {
                    state.buffer.append(leftover)
                }
            }
            drain(connection)   // already finished? handle right away
        } else if bodyAvailable >= contentLength {
            let dataNeeded = state.buffer.startIndex + (headText.utf8.count + 4 + contentLength)
            if contentLength > 0 {
                req.body = state.buffer.subdata(in: bodyStart..<dataNeeded)
            }
            state.buffer.removeSubrange(state.buffer.startIndex..<dataNeeded)
            state.sent100Continue = false
            handle(connection, req)
        } else if req.method == "PUT" && contentLength > Self.streamThreshold {
            // Stream large PUT to a temp file
            let tempFile = tmpBase.appendingPathComponent("put-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: tempFile.path) else {
                cleanup(connection)
                return
            }
            let overflow = min(bodyAvailable, contentLength)
            if overflow > 0 {
                try? handle.write(contentsOf: state.buffer.subdata(in: bodyStart..<state.buffer.index(bodyStart, offsetBy: overflow)))
                state.buffer.removeSubrange(state.buffer.startIndex..<state.buffer.index(bodyStart, offsetBy: overflow))
            }
            state.streamingHead = (req, tempFile, handle, Int64(contentLength - overflow))
            state.sent100Continue = false
            readNext(connection)
        } else {
            readNext(connection)   // need more body bytes
        }
    }

    // MARK: - Handling

    private func handle(_ connection: NWConnection, _ request: WebDAVRequest) {
        guard let handler = onRequest else { return }
        Task.detached { [weak self] in
            let response = await handler(request)
            self?.send(response, connection: connection) {
                let wantsClose = (request.header("connection") ?? "").lowercased() == "close"
                if wantsClose {
                    self?.cleanup(connection)
                } else {
                    self?.readNext(connection)
                }
            }
        }
    }

    // MARK: - Send

    private func send(_ response: WebDAVResponse, connection: NWConnection, completion: @escaping () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatus.phrase(response.status))\r\n"
        var hasLength = false
        for (name, value) in response.headers {
            if name.lowercased() == "content-length" { hasLength = true }
            head += "\(name): \(value)\r\n"
        }

        let bodyLength: Int64
        if let file = response.fileURL {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
            bodyLength = max(0, min(response.fileLength, (fileSize ?? 0) - response.fileOffset))
        } else {
            bodyLength = Int64(response.body?.count ?? 0)
        }
        if !hasLength {
            head += "Content-Length: \(bodyLength)\r\n"
        }
        head += "Connection: keep-alive\r\n\r\n"

        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.cleanup(connection)
                completion()
                return
            }
            self?.sendBody(response, remaining: bodyLength, connection: connection, completion: completion)
        })
    }

    private func sendBody(_ response: WebDAVResponse, remaining: Int64, connection: NWConnection, completion: @escaping () -> Void) {
        if remaining <= 0 {
            completion()
            return
        }

        if let file = response.fileURL {
            guard let handle = FileHandle(forReadingAtPath: file.path) else {
                completion()
                return
            }
            try? handle.seek(toOffset: UInt64(max(0, response.fileOffset)))
            sendFileChunks(handle, remaining: remaining, connection: connection, completion: completion)
        } else {
            let data = response.body ?? Data()
            send(data: data, remaining: Int64(data.count), connection: connection, completion: completion)
        }
    }

    /// Sends a file in fixed 1 MB chunks, chunk by chunk.
    private func sendFileChunks(_ handle: FileHandle, remaining: Int64, connection: NWConnection, completion: @escaping () -> Void) {
        let batchSize = Int(min(remaining, 1024 * 1024))
        let data = handle.readData(ofLength: batchSize)
        let actuallyRead = Int64(data.count)

        if actuallyRead <= 0 {
            completion()
            return
        }
        connection.send(content: data.prefix(Int(min(actuallyRead, Int64(batchSize)))), completion: .contentProcessed { [weak self] error in
            if error != nil || self?.isConnectionDead(connection) == true {
                self?.cleanup(connection)
                completion()
                return
            }
            self?.sendFileChunks(handle, remaining: remaining - actuallyRead, connection: connection, completion: completion)
        })
    }

    private func isConnectionDead(_ c: NWConnection) -> Bool {
        if case .failed = c.state { return true }
        if c.state == .cancelled { return true }
        return false
    }

    private func send(data: Data, remaining: Int64, connection: NWConnection, completion: @escaping () -> Void) {
        if remaining <= 0 {
            completion()
            return
        }
        let batch = Int(min(remaining, 1024 * 1024))
        let start = data.startIndex + Int(Int64(data.count) - remaining)
        let chunk = data.subdata(in: start..<start + batch)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil || self?.isConnectionDead(connection) == true {
                self?.cleanup(connection)
                completion()
                return
            }
            self?.send(data: data, remaining: remaining - Int64(chunk.count), connection: connection, completion: completion)
        })
    }
}
