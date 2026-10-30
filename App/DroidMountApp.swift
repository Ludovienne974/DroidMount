import SwiftUI

@main
struct DroidMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra("DroidMount", systemImage: "externaldrive.connected.to.line.below") {
            MenuBarContentView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
