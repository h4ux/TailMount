import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.usernamePromptNode != nil {
                usernamePrompt
            } else if appState.isLoading && appState.nodes.isEmpty {
                ProgressView("Discovering servers...")
                    .padding()
            } else if let error = appState.error {
                ErrorBanner(message: error) {
                    Task { await appState.refresh() }
                }
            } else if appState.nodes.isEmpty {
                emptyState
            } else {
                serverList
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("TailMount")
                .font(.headline)
            Spacer()
            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh server list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(appState.nodes) { node in
                    ServerRowView(
                        node: node,
                        state: appState.mountStates[node.dnsName] ?? .unmounted
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No SSH servers found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Make sure Tailscale is running and SSH is enabled on your nodes (port 22).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }

    private var usernamePrompt: some View {
        VStack(spacing: 10) {
            if let node = appState.usernamePromptNode {
                if let err = appState.usernamePromptError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.bottom, 4)
                }

                Text("SSH username for \(node.displayName)")
                    .font(.subheadline.bold())

                TextField("Username", text: $appState.usernamePromptText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task {
                            await appState.confirmUsernameAndMount(
                                node: node, username: appState.usernamePromptText
                            )
                        }
                    }

                HStack {
                    Button("Cancel") {
                        appState.dismissUsernamePrompt()
                    }
                    Spacer()
                    Button("Connect") {
                        Task {
                            await appState.confirmUsernameAndMount(
                                node: node, username: appState.usernamePromptText
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("Settings...")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit") {
                Task {
                    await appState.unmountAll()
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
