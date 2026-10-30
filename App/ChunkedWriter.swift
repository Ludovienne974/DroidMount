import Foundation

// MARK: - ChunkedWriter : incremental HTTP chunked (Transfer-Encoding) decoder.
// The Finder's webdavfs sends PUT with chunked encoding (no Content-Length).

final class ChunkedWriter: @unchecked Sendable {

    let tempFile: URL
    private let handle: FileHandle
    private var raw = Data()
    /// -1 = reading size line ; >0 = inside chunk data (remaining) ; 0... finish
    private var chunkRemaining = Int64(-1)
    private var pendingCRLF = 0
    private var trailerMode = false
    private(set) var finished = false
    private(set) var totalBytes: Int64 = 0

    init(tempFile: URL) {
        self.tempFile = tempFile
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        self.handle = FileHandle(forWritingAtPath: tempFile.path) ?? FileHandle.nullDevice
    }

    /// Feeds raw bytes; returns the leftover bytes that must NOT be consumed
    /// (bytes belonging to the next request if the body terminates mid-feed).
    func feed(_ data: Data) -> Data {
        guard !finished else { return data }
        raw.append(data)
        decode()
        if finished {
            let leftover = raw
            raw = Data()
            return leftover
        }
        return Data()
    }

    func finish() {
        if !finished {
            handle.closeFile()
            finished = true
        }
    }

    func close() {
        finished = true
        try? handle.close()
    }

    private func decode() {
        while !finished {
            if pendingCRLF > 0 {
                guard raw.count >= pendingCRLF else { return }
                raw.removeFirst(pendingCRLF)
                pendingCRLF = 0
                chunkRemaining = -1
                continue
            }

            if chunkRemaining == -1 {
                // Size line: "1A[;ext]\r\n"
                guard let crlf = raw.firstRange(of: Data("\r\n".utf8)) else { return }
                let lineData = raw.subdata(in: raw.startIndex..<crlf.lowerBound)
                let line = (String(data: lineData, encoding: .utf8) ?? "")
                    .components(separatedBy: ";").first ?? ""
                raw.removeSubrange(raw.startIndex..<crlf.upperBound)
                guard let size = Int64(line.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    // Malformed chunk: close
                    close()
                    return
                }
                if size == 0 {
                    trailerMode = true
                    chunkRemaining = 0
                    // wait the final CRLF (after optional trailers)
                    continue
                }
                chunkRemaining = size
                continue
            }

            if trailerMode {
                // Optionnel "Trailer: ..." then final "\r\n"
                if raw.prefix(2) == Data("\r\n".utf8) {
                    raw.removeFirst(2)
                    finish()
                    return
                }
                if raw.isEmpty {
                    return   // more bytes for trailers
                }
                // A trailer line: consume it
                if let crlf = raw.firstRange(of: Data("\r\n".utf8)) {
                    raw.removeSubrange(raw.startIndex..<crlf.upperBound)
                    continue
                } else if raw.count >= 2 {
                    raw.removeFirst(raw.count - (raw.count % 2 == 0 ? 0 : 1))
                    // the strange case of no complete line: keep the rest
                    return
                } else {
                    return
                }
            }

            // Delivered chunk data
            let available = Int64(raw.count)
            let take = min(available, chunkRemaining)
            if take > 0 {
                try? handle.write(contentsOf: raw.prefix(Int(take)))
                totalBytes += take
                raw.removeFirst(Int(take))
                chunkRemaining -= take
            }
            if chunkRemaining > 0 {
                return   // more data for current chunk
            }
            // Chunk data finished: consume the trailing CRLF, possibly by steps
            pendingCRLF = 2
            continue
        }
    }
}
