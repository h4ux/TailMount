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

        // 3. Mount at /Volumes/<name> so Finder shows the server name.
        //    /Volumes is root-owned, so we create the dir + mount via a single
        //    privilege-escalated shell command.
        let volumeName = node.displayName
        let mountPoint = "/Volumes/\(volumeName)"
        let mountURL = "http://127.0.0.1:\(port)/"

        try await mountWithPrivileges(url: mountURL, at: mountPoint, volumeName: volumeName)

        // 4. Track session
        sessions[node.dnsName] = MountSession(
            sftpBridge: sftpBridge,
            webDAVServer: webDAV,
            mountPoint: mountPoint,
            port: port
        )
    }

    func unmount(dnsName: String) async throws {
        guard let session = sessions.removeValue(forKey: dnsName) else { return }
        try await unmountVolume(at: session.mountPoint)
        try? await session.webDAVServer.stop()
        try? await session.sftpBridge.disconnect()
        try? FileManager.default.removeItem(atPath: session.mountPoint)
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
            sessions.removeValue(forKey: dnsName)
        }
    }

    // MARK: - Private

    /// Create mount point in /Volumes and mount via a single admin-privileged command.
    /// macOS will show a one-time admin prompt the first time.
    private func mountWithPrivileges(url: String, at mountPoint: String, volumeName: String) async throws {
        // Escape single quotes for shell
        let safeMountPoint = mountPoint.replacingOccurrences(of: "'", with: "'\\''")
        let safeVolumeName = volumeName.replacingOccurrences(of: "'", with: "'\\''")
        let safeURL = url.replacingOccurrences(of: "'", with: "'\\''")

        let shellCmd = """
        mkdir -p '\(safeMountPoint)' && /sbin/mount_webdav -s -S -v '\(safeVolumeName)' '\(safeURL)' '\(safeMountPoint)'
        """

        // First try without privilege escalation (works if user has write access)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCmd]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 { return }

        // Fall back to admin privilege escalation via AppleScript
        let script = "do shell script \"\(shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Mount failed"
            throw MountError.mountFailed(msg)
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
