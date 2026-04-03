import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var nodes: [TailscaleNode] = []
    @Published var mountStates: [String: MountState] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var sshUsername: String

    /// Per-node username overrides (persisted)
    @Published var nodeUsernames: [String: String] = [:]

    /// Username prompt state
    @Published var usernamePromptNode: TailscaleNode?
    @Published var usernamePromptText: String = ""
    @Published var usernamePromptError: String?

    let tailscaleService = TailscaleService()
    let mountService = MountService()

    private var refreshTimer: Timer?

    var hasMountedServers: Bool {
        mountStates.values.contains { $0 == .mounted }
    }

    init() {
        self.sshUsername = UserDefaults.standard.string(forKey: "sshUsername") ?? NSUserName()
        if let saved = UserDefaults.standard.dictionary(forKey: "nodeUsernames") as? [String: String] {
            self.nodeUsernames = saved
        }
        Task { await refresh() }
        startAutoRefresh()
    }

    func refresh() async {
        isLoading = true
        error = nil
        do {
            nodes = try await tailscaleService.fetchNodes()
            let currentDNSNames = Set(nodes.map(\.dnsName))
            mountStates = mountStates.filter { currentDNSNames.contains($0.key) }
            for node in nodes {
                if mountStates[node.dnsName] == nil {
                    mountStates[node.dnsName] = .unmounted
                }
                let mp = mountService.mountPointForNode(node)
                if mountService.isMounted(at: mp) {
                    mountStates[node.dnsName] = .mounted
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func toggleMount(for node: TailscaleNode) async {
        let state = mountStates[node.dnsName] ?? .unmounted
        switch state {
        case .unmounted, .error:
            await doMount(node: node)
        case .mounted:
            mountStates[node.dnsName] = .unmounting
            do {
                try await mountService.unmount(dnsName: node.dnsName)
                mountStates[node.dnsName] = .unmounted
            } catch {
                mountStates[node.dnsName] = .error(error.localizedDescription)
            }
        case .mounting, .unmounting:
            break
        }
    }

    private func usernameForNode(_ node: TailscaleNode) -> String {
        nodeUsernames[node.dnsName]
            ?? sshConfigUsername(for: node)
            ?? sshUsername
    }

    private func doMount(node: TailscaleNode) async {
        let username = usernameForNode(node)
        mountStates[node.dnsName] = .mounting

        do {
            let mp = mountService.mountPointForNode(node)
            try await mountService.mount(node: node, at: mp, username: username)
            mountStates[node.dnsName] = .mounted
        } catch {
            mountStates[node.dnsName] = .unmounted
            usernamePromptText = username
            usernamePromptError = error.localizedDescription
            usernamePromptNode = node
        }
    }

    func confirmUsernameAndMount(node: TailscaleNode, username: String) async {
        nodeUsernames[node.dnsName] = username
        UserDefaults.standard.set(nodeUsernames, forKey: "nodeUsernames")
        usernamePromptNode = nil
        usernamePromptError = nil
        await doMount(node: node)
    }

    func dismissUsernamePrompt() {
        usernamePromptNode = nil
        usernamePromptError = nil
    }

    func revealInFinder(_ node: TailscaleNode) {
        let path = mountService.mountPointForNode(node)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func updateSSHUsername(_ username: String) {
        sshUsername = username
        UserDefaults.standard.set(username, forKey: "sshUsername")
    }

    func unmountAll() async {
        await mountService.unmountAll()
        for key in mountStates.keys { mountStates[key] = .unmounted }
    }

    /// Parse ~/.ssh/config to find the User for a given host.
    private func sshConfigUsername(for node: TailscaleNode) -> String? {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        let hostNames = [node.displayName, node.hostName, node.primaryIP].compactMap { $0 }
        let lines = content.components(separatedBy: .newlines)
        var currentHostMatches = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("host ") {
                let hostPattern = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                currentHostMatches = hostNames.contains { host in
                    hostPattern.split(separator: " ").contains { Substring(host) == $0 }
                }
            } else if currentHostMatches, trimmed.lowercased().hasPrefix("user ") {
                return trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }
}
