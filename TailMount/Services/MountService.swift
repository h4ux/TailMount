import Foundation

/// Manages mount sessions: SFTP connection → WebDAV server → macOS mount.
/// Each mounted node gets its own SFTP bridge + local WebDAV server.
final class MountService {
    private var sessions: [String: MountSession] = [:]

    struct MountSession {
        let sftpBridge: SFTPBridge
        let webDAVServer: WebDAVServer
        let mountPoint: String
        let port: Int
        let hostsAlias: String
    }

    func mount(node: TailscaleNode, at _: String, username: String) async throws {
        let host = node.primaryIP ?? node.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // 1. Connect via SFTP
        let sftpBridge = SFTPBridge(host: host, username: username)
        try await sftpBridge.connect()

        // 2. Start local WebDAV server
        let webDAV = WebDAVServer(sftpBridge: sftpBridge)
        try await webDAV.start()
        let port = webDAV.port

        // 3. Prepare mount point in /Volumes and hosts alias
        let volumeName = node.displayName
        let mountPoint = "/Volumes/\(volumeName)"
        // Hosts alias: used so Finder sidebar shows the server name instead of 127.0.0.1
        let hostsAlias = "tailmount-\(volumeName)"
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()

        // Single admin prompt: create mount dir + add hosts entry
        try await setupMount(mountPoint: mountPoint, hostsAlias: hostsAlias)

        // 4. Mount using the hostname alias
        let mountURL = "http://\(hostsAlias):\(port)/"
        try mountWebDAV(url: mountURL, at: mountPoint, volumeName: volumeName)

        // 5. Track session
        sessions[node.dnsName] = MountSession(
            sftpBridge: sftpBridge,
            webDAVServer: webDAV,
            mountPoint: mountPoint,
            port: port,
            hostsAlias: hostsAlias
        )
    }

    func unmount(dnsName: String) async throws {
        guard let session = sessions.removeValue(forKey: dnsName) else { return }
        try await unmountVolume(at: session.mountPoint)
        try? await session.webDAVServer.stop()
        try? await session.sftpBridge.disconnect()
        try? FileManager.default.removeItem(atPath: session.mountPoint)
        removeHostsAlias(session.hostsAlias)
    }

    func isMounted(at mountPoint: String) -> Bool {
        var st = statfs()
        guard statfs(mountPoint, &st) == 0 else { return false }
        let parentPath = (mountPoint as NSString).deletingLastPathComponent
        var parentSt = statfs()
        guard statfs(parentPath, &parentSt) == 0 else { return false }
        return st.f_fsid.val.0 != parentSt.f_fsid.val.0
            || st.f_fsid.val.1 != parentSt.f_fsid.val.1
    }

    func mountPointForNode(_ node: TailscaleNode) -> String {
        if let session = sessions[node.dnsName] {
            return session.mountPoint
        }
        return "/Volumes/\(node.displayName)"
    }

    func unmountAll() async {
        for (dnsName, session) in sessions {
            try? await unmountVolume(at: session.mountPoint)
            try? await session.webDAVServer.stop()
            try? await session.sftpBridge.disconnect()
            try? FileManager.default.removeItem(atPath: session.mountPoint)
            removeHostsAlias(session.hostsAlias)
            sessions.removeValue(forKey: dnsName)
        }
    }

    // MARK: - Private

    /// Create mount point in /Volumes and add a hosts entry, with a single admin prompt.
    private func setupMount(mountPoint: String, hostsAlias: String) async throws {
        let safePath = mountPoint.replacingOccurrences(of: "'", with: "'\\''")

        // Clean stale mount point
        if FileManager.default.fileExists(atPath: mountPoint) && !isMounted(at: mountPoint) {
            try? FileManager.default.removeItem(atPath: mountPoint)
        }

        let uid = getuid()
        let gid = getgid()

        // Single admin command: create dir + add hosts alias
        var cmds: [String] = []
        if !FileManager.default.fileExists(atPath: mountPoint) {
            cmds.append("mkdir -p '\(safePath)' && chown \(uid):\(gid) '\(safePath)'")
        }
        // Add hosts entry if not already there
        cmds.append("grep -q '\(hostsAlias)' /etc/hosts || echo '127.0.0.1 \(hostsAlias)' >> /etc/hosts")

        let cmd = cmds.joined(separator: " && ")
        let script = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")
        var errorDict: NSDictionary?
        script?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Setup failed"
            throw MountError.mountFailed(msg)
        }
    }

    /// Remove the hosts alias (best-effort, no admin prompt).
    private func removeHostsAlias(_ alias: String) {
        let cmd = "sed -i '' '/\\b\(alias)\\b/d' /etc/hosts"
        let script = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")
        script?.executeAndReturnError(nil)
    }

    private func mountWebDAV(url: String, at mountPoint: String, volumeName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_webdav")
        process.arguments = ["-s", "-S", "-v", volumeName, url, mountPoint]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw MountError.mountFailed(errorMsg)
        }
    }

    private func unmountVolume(at mountPoint: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diskutil")
        process.arguments = ["unmount", mountPoint]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let force = Process()
            force.executableURL = URL(fileURLWithPath: "/usr/bin/diskutil")
            force.arguments = ["unmount", "force", mountPoint]
            force.standardOutput = Pipe()
            force.standardError = Pipe()
            try force.run()
            force.waitUntilExit()
        }
    }
}

enum MountError: LocalizedError {
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let msg): return "Mount failed: \(msg)"
        }
    }
}
