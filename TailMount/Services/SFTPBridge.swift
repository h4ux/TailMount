import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// Wraps Citadel's SSH/SFTP client for connecting to Tailscale nodes.
actor SFTPBridge {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    private let host: String
    private let username: String

    init(host: String, username: String) {
        self.host = host
        self.username = username
    }

    func connect() async throws {
        // Try "none" auth first (works with Tailscale SSH),
        // then fall back to password-based with empty password.
        let authMethod = NoneAuthDelegate(username: username)

        let client = try await SSHClient.connect(
            host: host,
            authenticationMethod: .custom(authMethod),
            hostKeyValidator: .acceptAnything(),
            reconnect: .always
        )
        self.sshClient = client
        self.sftpClient = try await client.openSFTP()
    }

    func disconnect() async throws {
        try await sftpClient?.close()
        try await sshClient?.close()
        sftpClient = nil
        sshClient = nil
    }

    var isConnected: Bool {
        sshClient != nil && sftpClient != nil
    }

    // MARK: - SFTP Operations

    func listDirectory(at path: String) async throws -> [SFTPEntry] {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        let result = try await sftp.listDirectory(atPath: path)
        return result.flatMap { nameMessage in
            nameMessage.components.compactMap { component -> SFTPEntry? in
                let name = component.filename
                guard name != "." && name != ".." else { return nil }
                let perms = component.attributes.permissions ?? 0
                let isDirectory = perms & 0o40000 != 0
                return SFTPEntry(
                    name: name,
                    fullPath: (path as NSString).appendingPathComponent(name),
                    isDirectory: isDirectory,
                    size: Int64(component.attributes.size ?? 0),
                    modified: component.attributes.accessModificationTime?.modificationTime ?? Date(),
                    permissions: perms
                )
            }
        }
    }

    func stat(at path: String) async throws -> SFTPEntry {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        let attrs = try await sftp.getAttributes(at: path)
        let name = (path as NSString).lastPathComponent
        let perms = attrs.permissions ?? 0
        let isDirectory = perms & 0o40000 != 0
        return SFTPEntry(
            name: name.isEmpty ? "/" : name,
            fullPath: path,
            isDirectory: isDirectory,
            size: Int64(attrs.size ?? 0),
            modified: attrs.accessModificationTime?.modificationTime ?? Date(),
            permissions: perms
        )
    }

    func readFile(at path: String) async throws -> Data {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        let file = try await sftp.openFile(filePath: path, flags: .read)
        let buffer = try await file.readAll()
        try await file.close()
        return Data(buffer: buffer)
    }

    func writeFile(at path: String, data: Data) async throws {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        try await file.write(buffer)
        try await file.close()
    }

    func createDirectory(at path: String) async throws {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        try await sftp.createDirectory(atPath: path)
    }

    func remove(at path: String, isDirectory: Bool) async throws {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        if isDirectory {
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        guard let sftp = sftpClient else { throw SFTPBridgeError.notConnected }
        try await sftp.rename(at: oldPath, to: newPath)
    }
}

// MARK: - "None" auth for Tailscale SSH

/// SSH "none" authentication delegate. Tailscale SSH authenticates based on
/// the WireGuard tunnel identity, so no password or key is needed.
private final class NoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .none
            )
        )
    }
}

// MARK: - Models

struct SFTPEntry {
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let permissions: UInt32
}

enum SFTPBridgeError: LocalizedError {
    case notConnected
    case authFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SFTP server"
        case .authFailed: return "SSH authentication failed"
        }
    }
}
