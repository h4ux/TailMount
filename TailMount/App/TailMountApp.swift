import SwiftUI

@main
struct TailMountApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("TailMount", systemImage: appState.hasMountedServers ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.wifi")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
