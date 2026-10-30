import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Mount state

enum MountState: Equatable {
    case notMounted
    case mounting
    case mounted(volumeURL: URL)
    case unmounting
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // Settings (persisted)
    @AppStorage("port") var port: Int = 5059
    @AppStorage("storageRoot") var storageRoot: String = "/storage/emulated/0"
    @AppStorage("autoMount") var autoMount: Bool = true

    // UI state
    @Published var adbPath: String?
    @Published var device: ADBDevice?
    @Published var unauthorizedDevicePresent = false
    @Published var mountState: MountState = .notMounted
    @Published var lastError: String?
    @Published var launchAtLogin: Bool = false
    @Published var freeSpace: String?

    private var adb: ADB?
    private var session: MountSession?
    private var pollTask: Task<Void, Never>?
    /// Serial for which the user has explicitly ejected — no auto-remount
    /// until disconnection/reconnection of the device.
    private var autoMountSuppressedSerial: String?

    private init() {
        adbPath = ADB.locate()
        if let path = adbPath {
            adb = ADB(path: path)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startPolling()
    }

    // MARK: Detection loop

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func refreshNow() {
        Task { await self.refreshOnce() }
    }

    private func refreshOnce() async {
        // ADB present?
        if adbPath == nil, let located = ADB.locate() {
            adbPath = located
            adb = ADB(path: located)
        }
        guard let adb else {
            NSLog("[DroidMount] adb introuvable")
            return
        }

        do {
            let devices = try await adb.listDevices()
            NSLog("[DroidMount] %d périphérique(s) détecté(s)", devices.count)
            for d in devices {
                NSLog("[DroidMount] appareil %@", "\(d.id) état=\(d.state) modèle=\(d.model)")
            }
            unauthorizedDevicePresent = devices.contains { $0.state == "unauthorized" }

            let connected = devices.first { $0.state == "device" }
            NSLog("[DroidMount] premier appareil autorisé : %@", connected?.id ?? "aucun")

            if let connected {
                if device?.id != connected.id {
                    // Device change / first connection: unmount a possible old volume
                    autoMountSuppressedSerial = nil
                    if mountState != .notMounted {
                        await unmount()
                    }
                    device = connected
                    NSLog("[DroidMount] nouvel appareil retenu : %@", connected.id)
                    await detectFreeSpace(adb: adb, serial: connected.id)
                }
                // Auto-mount on connect (unless the user ejects an explicit device)
                if autoMount,
                   device?.id != autoMountSuppressedSerial,
                   case .notMounted = mountState {
                    await mount()
                }
            } else {
                if device != nil {
                    device = nil
                    NSLog("[DroidMount] appareil débranché")
                    autoMountSuppressedSerial = nil
                }
                if mountState != .notMounted {
                    await unmount()
                }
            }
        } catch {
            NSLog("[DroidMount] erreur de détection : %@", error.localizedDescription)
        }

        // If the user ejected via Finder, we reset the state
        if case .mounted = mountState, session?.mountedVolumeURL() == nil {
            mountState = .notMounted
            session?.stopServer()
            session = nil
        }
    }

    /// Free space summary (parse of `df -h root`)
    private func detectFreeSpace(adb: ADB, serial: String) async {
        guard let res = try? await adb.shellOutput("df -h \(shellQuote(storageRoot))", serial: serial) else { return }
        let line = res.components(separatedBy: "\n").last ?? ""
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // toybox: fs size used avail use% mounted
        if tokens.count >= 4 {
            freeSpace = tokens[tokens.count - 4]
        }
    }

    // MARK: Actions

    func mount() async {
        guard let adb, let device, adbPath != nil else { return }
        guard case .notMounted = mountState else { return }

        mountState = .mounting
        lastError = nil

        let label = MountSession.sanitizeVolumeLabel(device.displayName)
        let session = MountSession(port: UInt16(clamping: port), label: label)
        self.session = session

        do {
            try session.startServer(adb: adb, serial: device.id, storageRoot: storageRoot)
        } catch {
            lastError = "Impossible de démarrer le serveur local sur le port \(port) : \(error.localizedDescription)"
            self.session = nil
            mountState = .notMounted
            return
        }

        // Laissant le Finder monter le volume en parallèle (osascript)
        Task {
            await session.openMountViaFinder()
        }

        // Wait up to 15 s for /Volumes/<label>*
        var mountedURL: URL?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let url = session.mountedVolumeURL() {
                mountedURL = url
                break
            }
        }

        if let url = mountedURL {
            NSLog("[DroidMount] monté sur \(url.path)")
            mountState = .mounted(volumeURL: url)
        } else {
            lastError = "Le montage via le Finder n'a pas abouti (délai dépassé). Vérifiez l'appareil et réessayez."
            session.stopServer()
            self.session = nil
            mountState = .notMounted
        }
    }

    func unmount() async {
        if case .notMounted = mountState { return }
        if case .unmounting = mountState { return }
        mountState = .unmounting

        if let session, let url = session.mountedVolumeURL() {
            _ = await MountSession.unmountVolume(url: url)
        }
        // Double-check with the last known label
        if let label = session?.label, let url = MountSession.findVolume(named: label) {
            _ = await MountSession.unmountVolume(url: url)
        }

        // Manual ejection: the auto-mount won't remount until the device is unplugged/replugged
        if let device {
            autoMountSuppressedSerial = device.id
        }
        session?.stopServer()
        session = nil
        mountState = .notMounted
    }

    /// URL of the mounted volume (label of the current session)
    var volumeURL: URL? {
        session?.mountedVolumeURL()
    }

    func revealInFinder() {
        guard let url = volumeURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            lastError = "Ouverture à la session : \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Called when the app quits (unmounts cleanly)
    func shutdown() {
        if let session, let url = session.mountedVolumeURL() {
            MountSession.unmountVolumeSync(url: url)
        }
        session?.stopServer()
        session = nil
        pollTask?.cancel()
    }
}

// MARK: - App delegate (clean exit)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
