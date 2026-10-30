import SwiftUI

// MARK: - Menu bar popover content

struct MenuBarContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            deviceSection
            Divider()
            settingsSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("DroidMount")
                    .font(.headline)
                Text("Stockage Android sur le Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        if app.adbPath == nil {
            missingADB
        } else if let device = app.device {
            deviceCard(device)
        } else if app.unauthorizedDevicePresent {
            unauthorizedCard
        } else {
            emptyCard
        }

        if let error = app.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var missingADB: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("adb introuvable", systemImage: "questionmark.folder")
                .font(.subheadline.weight(.semibold))
            Text("Installez Android Platform Tools, puis relancez DroidMount :")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("brew install --cask android-platform-tools")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install --cask android-platform-tools", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copier la commande")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func deviceCard(_ device: ADBDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("Série : \(device.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            switch app.mountState {
            case .notMounted:
                Button {
                    Task { await app.mount() }
                } label: {
                    Label("Monter le volume", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .mounting:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Montage en cours…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .mounted(let url):
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(url.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "network")
                            .foregroundStyle(.green)
                    }
                    .help(url.path)

                    HStack {
                        Button {
                            Task { await app.unmount() }
                        } label: {
                            Label("Éjecter", systemImage: "eject")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            app.revealInFinder()
                        } label: {
                            Label("Finder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            case .unmounting:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Éjection…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var unauthorizedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Autorisation requise", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("Déverrouillez votre appareil Android et validez l'autorisation « Débogage USB ».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Aucun appareil", systemImage: "cable.connector")
                .font(.subheadline.weight(.semibold))
            Text("Branchez votre appareil Android en USB avec le débogage USB activé (Options développeur).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Montage automatique à la connexion", isOn: $app.autoMount)
                .font(.caption)
                .disabled(!canChangeSettings)

            Toggle("Lancer au démarrage de la session", isOn: Binding(
                get: { app.launchAtLogin },
                set: { app.setLaunchAtLogin($0) }
            ))
            .font(.caption)

            HStack {
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Port", value: $app.port, format: .number.grouping(.never))
                    .frame(width: 70)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(!canChangeSettings)

                Text("Racine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                TextField("/sdcard", text: $app.storageRoot)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(!canChangeSettings)
            }
        }
    }

    private var canChangeSettings: Bool {
        switch app.mountState {
        case .notMounted: return true
        default: return false
        }
    }

    private var footer: some View {
        HStack {
            Button {
                app.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rafraîchir")

            Spacer()
            Button("Quitter DroidMount") {
                NSApp.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}
