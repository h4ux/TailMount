import Foundation

final class TailscaleService {
    private let tailscalePath: String

    init() {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        self.tailscalePath = candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "tailscale"
    }

    func fetchNodes() async throws -> [TailscaleNode] {
        let data = try await shellData(tailscalePath, arguments: ["status", "--json"])

        guard !data.isEmpty else {
            throw TailscaleError.commandFailed("Tailscale returned empty output")
        }

        let response: TailscaleStatusResponse
        do {
            response = try JSONDecoder().decode(TailscaleStatusResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw TailscaleError.commandFailed("Invalid JSON (\(data.count) bytes): \(preview)")
        }

        guard let peers = response.peer else { return [] }

        // Build candidate nodes: online, non-mobile OS, non-empty hostname
        let candidates: [TailscaleNode] = peers.compactMap { key, peer in
            let node = peer.toNode(id: key)
            let mobileOS = ["iOS", "tvOS", "android"]
            guard node.isOnline, !node.os.isEmpty, !mobileOS.contains(node.os) else { return nil }
            return node
        }

        // Probe SSH port (22) concurrently to find which nodes actually have SSH
        let sshNodes = await withTaskGroup(of: TailscaleNode?.self, returning: [TailscaleNode].self) { group in
            for node in candidates {
                group.addTask {
                    guard let ip = node.primaryIP else { return nil }
                    // If the node advertises SSHHostKeys, trust that
                    if node.hasSSH { return node }
                    // Otherwise, do a quick TCP connect to port 22
                    return Self.probeSSH(host: ip, timeoutSeconds: 1.5) ? node : nil
                }
            }
            var results: [TailscaleNode] = []
            for await node in group {
                if let node { results.append(node) }
            }
            return results
        }

        return sshNodes.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Quick TCP connect probe to check if SSH port is open.
    private static func probeSSH(host: String, timeoutSeconds: Double) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Set non-blocking
        let flags = fcntl(sock, F_GETFL, 0)
        fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        // Wait for connection with timeout using poll
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(timeoutSeconds * 1000)
        let pollResult = poll(&pfd, 1, timeoutMs)

        guard pollResult > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        // Check if connection actually succeeded
        var optErr: Int32 = 0
        var optLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &optErr, &optLen)
        return optErr == 0
    }

    private func shellData(_ command: String, arguments: [String]) async throws -> Data {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailmount-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        guard let stdoutHandle = FileHandle(forWritingAtPath: tempFile.path) else {
            throw TailscaleError.commandFailed("Could not create temp file")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = FileHandle.nullDevice
        // Tailscale macOS binary needs TERM set to run in CLI mode from a subprocess
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        do {
            try process.run()
        } catch {
            throw TailscaleError.processLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        try? stdoutHandle.close()

        guard process.terminationStatus == 0 else {
            throw TailscaleError.commandFailed("tailscale exited with status \(process.terminationStatus)")
        }

        return try Data(contentsOf: tempFile)
    }
}

enum TailscaleError: LocalizedError {
    case invalidOutput
    case processLaunchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput: return "Could not parse Tailscale output"
        case .processLaunchFailed(let msg): return msg
        case .commandFailed(let msg): return msg
        }
    }
}
