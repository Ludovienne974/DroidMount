import AppKit
import Foundation

// MARK: - MountSession : local WebDAV server + Finder native mount

final class MountSession: @unchecked Sendable {

    static let fallbackLabel = "DroidMount"

    let port: UInt16
    let label: String      // Finder volume name (= device name)

    private var server: WebDAVServer?
    private var vfs: AndroidVFS?

    init(port: UInt16, label: String) {
        self.port = port
        self.label = label
    }

    /// Volume name assembled from device name, sanitized for WebDAV URL
    static func sanitizeVolumeLabel(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.components(separatedBy: CharacterSet(charactersIn: "/:\\*?\"<>|").union(.newlines)).joined(separator: " ")
        // Collapse multiple spaces
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallbackLabel : cleaned
    }

    /// Starts the local WebDAV server bridged to `adb`.
    func startServer(adb: ADB, serial: String, storageRoot: String) throws {
        let vfs = AndroidVFS(adb: adb, serial: serial, storageRoot: storageRoot, mountLabel: label)
        let server = WebDAVServer(port: port)
        server.onRequest = { request in
            await vfs.handle(request)
        }
        try server.start()
        self.server = server
        self.vfs = vfs
    }

    func stopServer() {
        server?.stop()
        server = nil
        vfs?.clearCache()
        vfs = nil
    }

    var isRunning: Bool { server != nil }

    /// Asks the Finder to mount the WebDAV volume (AppleScript `mount volume`,
    /// the equivalent of ⌘K — `open webdav://…` no longer works via LaunchServices)
    func openMountViaFinder() async {
        let url = "http://localhost:\(port)/\(label)"
        let script = "tell application \"Finder\" to mount volume \"\(url)\""
        _ = await runProcessAsync("/usr/bin/osascript", ["-e", script])
    }

    // MARK: Volume detection / unmount

    /// Finds the mounted volume (label, or "label 2" when Finder dedupes)
    func mountedVolumeURL() -> URL? {
        Self.findVolume(named: label)
    }

    static func findVolume(named label: String) -> URL? {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.first { url in
            let name = url.lastPathComponent
            return name == label || name.hasPrefix("\(label) ")
        }
    }

    /// Asynchronous unmount (diskutil, then variants as fallback)
    static func unmountVolume(url: URL) async -> Bool {
        var result = await runProcessAsync("/usr/sbin/diskutil", ["unmount", url.path])
        if result.exitCode == 0 { return true }

        result = await runProcessAsync("/sbin/umount", [url.path])
        if result.exitCode == 0 { return true }

        result = await runProcessAsync("/usr/sbin/diskutil", ["unmount", "force", url.path])
        if result.exitCode == 0 { return true }

        result = await runProcessAsync("/sbin/umount", ["-f", url.path])
        return result.exitCode == 0
    }

    /// Synchronous unmount (may be called on app quit)
    static func unmountVolumeSync(url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["unmount", "force", url.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // ignore
        }
    }
}
