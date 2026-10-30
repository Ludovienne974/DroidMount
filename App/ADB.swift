import Foundation

// MARK: - ADB wrapper

enum ADBError: LocalizedError {
    case notFound
    case noDevice
    case shellError(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "La commande adb est introuvable."
        case .noDevice: return "Aucun appareil Android détecté."
        case .shellError(let msg): return msg
        }
    }
}

struct ADBDevice: Identifiable, Hashable {
    let id: String        // serial
    let model: String
    let state: String     // "device" | "unauthorized" | "offline" | ...

    var displayName: String {
        model.isEmpty ? id : model
    }
}

final class ADB: @unchecked Sendable {

    private let adbPath: String?

    init(path: String?) {
        self.adbPath = path
    }

    static func locate() -> String? {
        let candidates: [String] = [
            "~/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
        ]
        for p in candidates {
            let expanded = (p as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    func run(_ args: [String]) async throws -> String {
        guard let adb = adbPath else { throw ADBError.notFound }
        let res = await runProcessAsync(adb, args)
        guard res.exitCode == 0 else { throw ADBError.shellError(res.stderr) }
        return res.stdout
    }

    // MARK: Device listing

    func listDevices() async throws -> [ADBDevice] {
        let out = try await run(["devices", "-l"])
        let serialRegex = try? NSRegularExpression(pattern: #"model:(\S+)"#)

        var devices: [ADBDevice] = []
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("List of"),
                  !trimmed.hasPrefix("*") else { continue }

            let parts = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]

            var model = ""
            if let regex = serialRegex,
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                model = String(trimmed[range]).replacingOccurrences(of: "_", with: " ")
            }
            devices.append(ADBDevice(id: serial, model: model, state: state))
        }
        return devices
    }

    // MARK: Shell helpers

    private func shellArgs(_ command: String, serial: String) -> [String] {
        ["-s", serial, "shell", command]
    }

    func shell(_ command: String, serial: String) async throws -> ProcessResult {
        guard let adb = adbPath else { throw ADBError.notFound }
        return await runProcessAsync(adb, shellArgs(command, serial: serial))
    }

    func shellOutput(_ command: String, serial: String) async throws -> String {
        let res = try await shell(command, serial: serial)
        guard res.exitCode == 0 else { throw ADBError.shellError(res.stderr) }
        return res.stdout
    }

    /// Exit code of a shell command (i.e. `test -d path`)
    func shellExitCode(_ command: String, serial: String) async -> Int32 {
        (try? await shell(command, serial: serial))?.exitCode ?? -1
    }

    func isDirectory(_ path: String, serial: String) async -> Bool {
        await shellExitCode("test -d \(shellQuote(path))", serial: serial) == 0
    }

    func fileExists(_ path: String, serial: String) async -> Bool {
        await shellExitCode("test -e \(shellQuote(path))", serial: serial) == 0
    }

    // MARK: File transfers

    func pull(remotePath: String, to destination: URL, serial: String) async throws {
        guard let adb = adbPath else { throw ADBError.notFound }
        let res = await runProcessAsync(adb, ["-s", serial, "pull", remotePath, destination.path])
        guard res.exitCode == 0 else {
            throw ADBError.shellError("adb pull a échoué : \(res.stderr)")
        }
    }

    func push(localFile: URL, to remotePath: String, serial: String) async throws {
        guard let adb = adbPath else { throw ADBError.notFound }
        let res = await runProcessAsync(adb, ["-s", serial, "push", localFile.path, remotePath])
        guard res.exitCode == 0 else {
            throw ADBError.shellError("adb push a échoué : \(res.stderr)")
        }
    }
}

// MARK: - Shell table parsing ("ls -la" on Android devices — toybox format)

struct FSItem {
    let name: String
    let size: Int64?
    let isDirectory: Bool
    let mtime: Date?
}

extension ADB {

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parses one or more lines of Android's `ls -la`.
    /// Two date formats exist depending on the device / age of the file:
    ///   ISO toybox :  -rw-rw---- 1 root ext 12345 2025-11-30 09:12 notes.txt
    ///   BSD month  :  -rw-rw---- 1 root ext 12345 Nov 30 09:12 notes.txt
    ///                -rw-rw---- 1 root ext 12345 Nov 30 2023 notes.txt
    /// Layout: perms | links | user | group | size | date tokens | name
    private func parseLsLine(_ raw: String) -> FSItem? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("total"), line.count >= 9 else { return nil }

        var tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // token 0: permissions -> file type
        let perms = tokens.removeFirst()
        let isDir = perms.first == "d"

        // tokens[0] = links, [1] = user, [2] = group, [3] = size, [4...] = date + name
        guard tokens.count >= 6, let size = Int64(tokens[3]) else { return nil }
        let firstDateToken = tokens[4]

        var name: String
        var mtime: Date?

        // ISO format: "2025-11-30 09:12"
        if firstDateToken.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            guard tokens.count >= 7 else { return nil }
            name = tokens[6...].joined(separator: " ")
            mtime = Self.isoDateFormatter.date(from: firstDateToken + " " + tokens[5])
        }
        // BSD format: "Nov 30 09:12" or "Nov 30 2023"
        else if firstDateToken.range(of: #"^[A-Za-z]{3}$"#, options: .regularExpression) != nil {
            guard tokens.count >= 8 else { return nil }
            name = tokens[7...].joined(separator: " ")
            let yearOrTime = tokens[6]
            if yearOrTime.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil {
                // Recency: no year -> current year, minus 1 if in the future
                if let d = Self.monthTimeFormatter.date(from: "\(firstDateToken) \(tokens[5]) \(yearOrTime)") {
                    mtime = adjustToCurrentOrLastYear(d)
                }
            } else {
                mtime = Self.monthYearFormatter.date(from: "\(firstDateToken) \(tokens[5]) \(yearOrTime)")
            }
        }
        else {
            return nil   // unrecognized format
        }

        guard name != "." && name != ".." else { return nil }
        return FSItem(name: name, size: size, isDirectory: isDir, mtime: mtime)
    }

    /// When the year is absent (BSD recent date), if the date is more than
    /// 180 days in the future, it actually belongs to the previous year.
    private func adjustToCurrentOrLastYear(_ date: Date) -> Date {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days > 180 {
            return Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date
        }
        return date
    }

    func statItem(_ path: String, serial: String) async -> FSItem? {
        // A single item: most reliable is `ls -la path` on its parent for dirs vs files.
        // For a FILE: `ls -la path` prints the file line directly.
        guard let out = try? await shellOutput("ls -ldL \(shellQuote(path))", serial: serial) else { return nil }
        for line in out.components(separatedBy: "\n") {
            if let item = parseLsLine(line) { return item }
        }
        return nil
    }

    func listDirectory(_ path: String, serial: String) async throws -> [FSItem] {
        let out = try await shellOutput("ls -laL \(shellQuote(path))", serial: serial)
        return out.components(separatedBy: "\n").compactMap { parseLsLine($0) }
    }
}
