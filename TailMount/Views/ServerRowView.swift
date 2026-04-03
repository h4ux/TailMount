import SwiftUI

struct ServerRowView: View {
    @EnvironmentObject var appState: AppState
    let node: TailscaleNode
    let state: MountState

    var body: some View {
        Button {
            guard !state.isBusy else { return }
            Task { await appState.toggleMount(for: node) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: node.osIcon)
                    .font(.title3)
                    .foregroundStyle(state == .mounted ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(node.primaryIP ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !node.os.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(node.os)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Group {
                    switch state {
                    case .mounting, .unmounting:
                        ProgressView()
                            .controlSize(.small)

                    case .mounted:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                    case .unmounted:
                        Image(systemName: "eject")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(state == .mounted ? Color.green.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if state == .mounted {
                Button("Open in Finder") {
                    appState.revealInFinder(node)
                }
                Button("Unmount") {
                    Task { await appState.toggleMount(for: node) }
                }
            } else if !state.isBusy {
                Button("Mount") {
                    Task { await appState.toggleMount(for: node) }
                }
            }
        }
    }
}
