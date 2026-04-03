import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingUsername: String = ""

    var body: some View {
        Form {
            Section("SSH Connection") {
                TextField("Default username", text: $editingUsername)
                    .textFieldStyle(.roundedBorder)
                Text("Used when no per-node username is set and ~/.ssh/config has no match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dependencies") {
                dependencyRow(name: "Tailscale", paths: [
                    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                    "/usr/local/bin/tailscale",
                    "/opt/homebrew/bin/tailscale",
                ])
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Mount point", value: "/Volumes/<server-name>")
                LabeledContent("Architecture", value: "Built-in SFTP + WebDAV bridge")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
        .onAppear { editingUsername = appState.sshUsername }
        .onDisappear { appState.updateSSHUsername(editingUsername) }
    }

    private func dependencyRow(name: String, paths: [String]) -> some View {
        let found = paths.first { FileManager.default.fileExists(atPath: $0) }
        return LabeledContent(name) {
            if let path = found {
                VStack(alignment: .trailing) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Label("Not found", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
