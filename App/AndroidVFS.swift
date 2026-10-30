import Foundation
import UniformTypeIdentifiers

// MARK: - AndroidVFS : converts WebDAV requests into adb operations

final class AndroidVFS: @unchecked Sendable {

    private let adb: ADB
    private let serial: String
    private let storageRoot: String        // e.g. "/sdcard"
    private let mountLabel: String
    private let cacheDirectory: URL
    private var cacheIndex: [String: URL] = [:]
    private var cacheLock = NSLock()

    init(adb: ADB, serial: String, storageRoot: String, mountLabel: String) {
        self.adb = adb
        self.serial = serial
        self.mountLabel = mountLabel
        var root = storageRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        self.storageRoot = root

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMountCache-\(serial)", isDirectory: true)
        cacheDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var mountedURLPathBase: String { "/" + mountLabel }

    // MARK: Path mapping

    /// "/DroidMount/DCIM/a.png" -> "/sdcard/DCIM/a.png"
    private func remotePath(for requestPath: String) -> String? {
        var p = requestPath
        let base = mountedURLPathBase
        if p == base { p = "/" }
        else if p.hasPrefix(base + "/") { p = String(p.dropFirst(base.count)) }
        // If mounting used a different label/prefix, ignore it and use whole path
        guard !p.split(separator: "/").contains("..") else { return nil }
        if p == "/" || p.isEmpty { return storageRoot }
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return storageRoot + p
    }

    private func cleanUpTemp(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Request entry point

    func handle(_ request: WebDAVRequest) async -> WebDAVResponse {
        NSLog("[DroidMount] %@ %@", request.method, request.path)
        let response: WebDAVResponse
        do {
            response = try await route(request)
        } catch {
            NSLog("[DroidMount] ERREUR %@ %@ -> %@", request.method, request.path, error.localizedDescription)
            cleanUpTemp(fileTempFromRequest(request))
            return WebDAVResponse(
                status: 502,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: Data(("Erreur adb : " + error.localizedDescription).utf8)
            )
        }
        if response.status >= 400 {
            NSLog("[DroidMount] %d réponses en erreur -> %@", response.status, request.path)
        }
        return response
    }

    private func route(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        switch request.method {
            case "OPTIONS":
                return WebDAVResponse(
                    status: 200,
                    headers: [
                        ("Allow", "OPTIONS,PROPFIND,GET,HEAD,PUT,DELETE,MKCOL,MOVE,COPY,LOCK,UNLOCK"),
                        ("DAV", "1, 2"),
                        ("MS-Author-Via", "DAV"),
                    ]
                )
            case "PROPFIND":
                return try await propfind(request)
            case "GET", "HEAD":
                return try await get(request)
            case "PUT":
                return try await put(request)
            case "MKCOL":
                return try await mkcol(request)
            case "DELETE":
                return try await delete(request)
            case "MOVE", "COPY":
                return try await moveOrCopy(request)
            case "PROPPATCH":
                return try await proppatch(request)
            case "LOCK":
                return lockResponse(request)
            case "UNLOCK":
                return WebDAVResponse.status(204)
            default:
                return WebDAVResponse(
                    status: 405,
                    headers: [("Allow", "OPTIONS,PROPFIND,GET,HEAD,PUT,DELETE,MKCOL,MOVE,COPY,LOCK,UNLOCK")]
                )
            }
    }

    private func fileTempFromRequest(_ request: WebDAVRequest) -> URL? {
        request.header("x-droidmount-temp-file").map { URL(fileURLWithPath: $0) }
    }

    // MARK: PROPFIND

    private func propfind(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let remote = remotePath(for: request.path) else { return .status(400) }

        guard let isDir = await existsAndDirectory(remote) else { return .status(404) }

        let depth = (request.header("depth") ?? "1").lowercased() == "0" ? 0 : 1
        var entries: [(href: String, item: FSItem)] = []

        let selfHref = hrefBuilder.makeRemoteHref(virtualPath: request.path, isDirectory: isDir)
        let comps = request.path.split(separator: "/").map { String($0) }
        let effectiveName = comps.last ?? String(mountLabel.dropFirst())

        var selfItem = FSItem(name: effectiveName, size: nil, isDirectory: isDir, mtime: nil)
        if !isDir, let stat = await adb.statItem(remote, serial: serial) {
            selfItem = FSItem(name: effectiveName, size: stat.size, isDirectory: false, mtime: stat.mtime)
        }
        entries.append((selfHref, selfItem))

        if depth == 1 && isDir {
            let children = try await adb.listDirectory(remote, serial: serial)
            let base = request.path.hasSuffix("/") ? request.path : request.path + "/"
            for child in children {
                let childPath = base + child.name
                let childHref = hrefBuilder.makeRemoteHref(virtualPath: childPath, isDirectory: child.isDirectory)
                entries.append((childHref, child))
            }
        }

        let xml = multistatusXML(entries)
        return WebDAVResponse(
            status: 207,
            headers: [("Content-Type", "text/xml; charset=utf-8")],
            body: Data(xml.utf8)
        )
    }

    // MARK: GET / HEAD

    private func get(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let remote = remotePath(for: request.path), remote != storageRoot else { return .status(404) }

        let isDir = await adb.isDirectory(remote, serial: serial)
        guard !isDir else { return .status(405) }

        guard let stat = await adb.statItem(remote, serial: serial), let total = stat.size else {
            return .status(404)
        }
        if total == 0 {
            // Zero size: still needs to exist (touch) — respond to the empty file
            let mime = contentType(for: remote)
            return WebDAVResponse(status: 200, headers: [("Content-Type", mime), ("Content-Length", "0")], body: Data())
        }

        // Pull into local cache (once per file)
        let local = try await cachedCopy(of: remote)
        let contentTypeValue = contentType(for: remote)

        // Range support (Finder does it during big copies)
        if let rangeHeader = request.header("range"), rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst(6)
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if let start = Int64(parts.first ?? ""), start >= 0, start < total {
                var length = total - start
                if parts.count == 2, !parts[1].isEmpty, let end = Int64(parts[1]), end >= start {
                    length = min(length, end - start + 1)
                }
                if length > 0 {
                    return WebDAVResponse(
                        status: 206,
                        headers: [
                            ("Content-Type", contentTypeValue),
                            ("Content-Range", "bytes \(start)-\(start + length - 1)/\(total)"),
                        ],
                        fileURL: local,
                        fileOffset: start,
                        fileLength: length
                    )
                }
            }
        }

        let response = WebDAVResponse(
            status: 200,
            headers: [("Content-Type", contentTypeValue)],
            fileURL: local,
            fileOffset: 0,
            fileLength: total
        )
        if request.method == "HEAD" {
            var head = response
            head.fileURL = nil
            head.body = Data()
            return head
        }
        return response
    }

    // MARK: PUT

    private func put(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let remote = remotePath(for: request.path) else { return .status(400) }
        let tempFile = fileTempFromRequest(request)

        let isDir = await adb.isDirectory(remote, serial: serial)
        if isDir { return .status(405) }

        let existedBefore = await adb.fileExists(remote, serial: serial)

        // Write the body to a local temp file
        var localTemp: URL
        if let streamingTemFile = tempFile {
            localTemp = streamingTemFile
        } else {
            localTemp = cacheDirectory.appendingPathComponent("put-\(UUID().uuidString)")
            try request.body.write(to: localTemp)
        }

        do {
            try await adb.push(localFile: localTemp, to: remotePathString(remote), serial: serial)
        } catch {
            cleanUpTemp(localTemp)
            throw error
        }
        cleanUpTemp(localTemp)

        return WebDAVResponse.status(existedBefore ? 200 : 201)
    }

    private func remotePathString(_ remote: String) -> String { remote }

    // MARK: MKCOL

    private func mkcol(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let remote = remotePath(for: request.path) else { return .status(400) }
        guard remote != storageRoot else { return .status(405) }

        if await adb.fileExists(remote, serial: serial) { return .status(405) }

        // Parent missing -> 409
        let parent = (remote as NSString).deletingLastPathComponent
        guard await adb.isDirectory(parent, serial: serial) else { return .status(409) }

        _ = try await adb.shellOutput("mkdir \(shellQuote(remote))", serial: serial)
        return .status(201)
    }

    // MARK: DELETE

    private func delete(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let remote = remotePath(for: request.path) else { return .status(400) }
        guard remote != storageRoot else { return .status(403) }   // on ne supprime jamais la racine

        guard await adb.fileExists(remote, serial: serial) else { return .status(404) }

        _ = try await adb.shellOutput("rm -rf \(shellQuote(remote))", serial: serial)
        return .status(204)
    }

    // MARK: MOVE / COPY

    private func moveOrCopy(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        guard let source = remotePath(for: request.path) else { return .status(400) }
        guard await adb.fileExists(source, serial: serial) else { return .status(404) }

        guard let destHeader = request.header("destination"),
              let destURL = URL(string: destHeader) else { return .status(400) }
        guard let destination = remotePath(for: destURL.path) else { return .status(400) }
        guard source != destination && destination != storageRoot else { return .status(403) }

        // Parent of the destination present?
        let parent = (destination as NSString).deletingLastPathComponent
        guard await adb.isDirectory(parent, serial: serial) else { return .status(409) }

        let overwriteAllowed = (request.header("overwrite") ?? "T").uppercased() != "F"
        if await adb.fileExists(destination, serial: serial) {
            guard overwriteAllowed else { return .status(412) }
            _ = try await adb.shellOutput("rm -rf \(shellQuote(destination))", serial: serial)
        }

        let verb = request.method == "MOVE" ? "mv" : "cp -R"
        _ = try await adb.shellOutput("\(verb) \(shellQuote(source)) \(shellQuote(destination))", serial: serial)
        return .status(201)
    }

    // MARK: PROPPATCH (Finder sets fake dates, we accept)

    private func proppatch(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>\(xmlEscape(hrefBuilder.makeRemoteHref(virtualPath: request.path, isDirectory: true)))</D:href>
            <D:propstat>
              <D:prop></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        return WebDAVResponse(
            status: 207,
            headers: [("Content-Type", "text/xml; charset=utf-8")],
            body: Data(xml.utf8)
        )
    }

    private func lockResponse(_ request: WebDAVRequest) -> WebDAVResponse {
        let token = "urn:uuid:\(UUID().uuidString)"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
          <D:lockdiscovery>
            <D:activelock>
              <D:locktype><D:write/></D:locktype>
              <D:lockscope><D:exclusive/></D:lockscope>
              <D:depth>0</D:depth>
              <D:owner>\(xmlEscape(ownerFrom(request)))</D:owner>
              <D:timeout>Second-600</D:timeout>
              <D:locktoken><D:href>\(token)</D:href></D:locktoken>
              <D:lockroot><D:href>\(xmlEscape(hrefBuilder.makeRemoteHref(virtualPath: request.path, isDirectory: false)))</D:href></D:lockroot>
            </D:activelock>
          </D:lockdiscovery>
        </D:prop>
        """
        return WebDAVResponse(
            status: 200,
            headers: [
                ("Content-Type", "text/xml; charset=utf-8"),
                ("Lock-Token", "<\(token)>"),
            ],
            body: Data(xml.utf8)
        )
    }

    private func ownerFrom(_ request: WebDAVRequest) -> String {
        if let body = String(data: request.body, encoding: .utf8), !body.isEmpty {
            return String(body.prefix(200))
        }
        return "DroidMount"
    }

    // MARK: Exists helpers

    private func existsAndDirectory(_ remote: String) async -> Bool? {
        guard await adb.fileExists(remote, serial: serial) else { return nil }
        return await adb.isDirectory(remote, serial: serial)
    }

    // MARK: Cached copies

    private func cachedCopy(of remote: String) async throws -> URL {
        cacheLock.lock()
        if let cached = cacheIndex[remote] {
            if FileManager.default.fileExists(atPath: cached.path) {
                cacheLock.unlock()
                return cached
            }
            cacheIndex.removeValue(forKey: remote)
        }
        cacheLock.unlock()

        let name = UUID().uuidString
        var destination = cacheDirectory.appendingPathComponent(name)
        let ext = (remote as NSString).pathExtension
        if !ext.isEmpty { destination.appendPathExtension(ext) }

        try await adb.pull(remotePath: remote, to: destination, serial: serial)

        cacheLock.lock()
        cacheIndex[remote] = destination
        cacheLock.unlock()
        return destination
    }

    func clearCache() {
        cacheLock.lock()
        let entries = cacheIndex.values
        cacheIndex.removeAll()
        cacheLock.unlock()
        for url in entries {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: XML building

    private let hrefBuilder = HrefHelper()

    private func multistatusXML(_ entries: [(href: String, item: FSItem)]) -> String {
        let rfc1123: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            return f
        }()
        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        for (href, item) in entries {
            body += "  <D:response>\n"
            body += "    <D:href>\(xmlEscape(href))</D:href>\n"
            body += "    <D:propstat><D:prop>\n"
            if item.isDirectory {
                body += "      <D:resourcetype><D:collection/></D:resourcetype>\n"
            } else {
                body += "      <D:resourcetype/>\n"
                if let size = item.size {
                    body += "      <D:getcontentlength>\(size)</D:getcontentlength>\n"
                }
                body += "      <D:getcontenttype>\(xmlEscape(contentType(for: item.name)))</D:getcontenttype>\n"
            }
            body += "      <D:displayname>\(xmlEscape(item.name))</D:displayname>\n"
            if let mtime = item.mtime {
                body += "      <D:getlastmodified>\(rfc1123.string(from: mtime))</D:getlastmodified>\n"
                body += "      <D:creationdate>\(isoFormatter.string(from: mtime))</D:creationdate>\n"
            } else {
                let now = Date()
                body += "      <D:getlastmodified>\(rfc1123.string(from: now))</D:getlastmodified>\n"
                body += "      <D:creationdate>\(isoFormatter.string(from: now))</D:creationdate>\n"
            }
            body += "    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>\n"
            body += "  </D:response>\n"
        }
        body += "</D:multistatus>"
        return body
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func contentType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

// MARK: - Href helpers

struct HrefHelper {
    func makeRemoteHref(virtualPath: String, isDirectory: Bool) -> String {
        let comps = virtualPath.split(separator: "/").map { String($0) }
        guard !comps.isEmpty else {
            return isDirectory ? "/" : "/"
        }
        let encoded = comps.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: Self.allowedURLChars.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
        }
        var href = "/" + encoded.joined(separator: "/")
        if isDirectory && !href.hasSuffix("/") { href += "/" }
        return href
    }

    static let allowedURLChars = CharacterSet(charactersIn: "-._~!$&'()*+,;=:@/").union(.alphanumerics)
}
