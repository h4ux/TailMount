import Foundation

struct TailscaleNode: Identifiable, Equatable {
    let id: String        // node key
    let hostName: String
    let dnsName: String
    let ipAddresses: [String]
    let os: String
    let isOnline: Bool
    let sshHostKeys: [String]

    var displayName: String {
        // Strip trailing dot and tailnet suffix from DNS name
        let clean = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return clean.components(separatedBy: ".").first ?? hostName
    }

    var hasSSH: Bool {
        !sshHostKeys.isEmpty
    }

    var primaryIP: String? {
        ipAddresses.first
    }

    var osIcon: String {
        switch os.lowercased() {
        case let o where o.contains("linux"):  return "server.rack"
        case let o where o.contains("macos"):  return "laptopcomputer"
        case let o where o.contains("windows"): return "pc"
        default: return "desktopcomputer"
        }
    }
}

// MARK: - JSON Parsing from `tailscale status --json`

struct TailscaleStatusResponse: Decodable {
    let peer: [String: TailscalePeer]?

    enum CodingKeys: String, CodingKey {
        case peer = "Peer"
    }
}

struct TailscalePeer: Decodable {
    let hostName: String
    let dnsName: String
    let tailscaleIPs: [String]?
    let os: String
    let online: Bool
    let sshHostKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case os = "OS"
        case online = "Online"
        case sshHostKeys = "SSHHostKeys"
    }

    func toNode(id: String) -> TailscaleNode {
        TailscaleNode(
            id: id,
            hostName: hostName,
            dnsName: dnsName,
            ipAddresses: tailscaleIPs ?? [],
            os: os,
            isOnline: online,
            sshHostKeys: sshHostKeys ?? []
        )
    }
}
