import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// A minimal WebDAV server backed by an SFTPBridge.
/// Runs on localhost and serves files from the remote server.
final class WebDAVServer {
    private let sftpBridge: SFTPBridge
    private let remotePath: String
    private var channel: Channel?
    private let group: EventLoopGroup

    private(set) var port: Int = 0

    init(sftpBridge: SFTPBridge, remotePath: String = "/") {
        self.sftpBridge = sftpBridge
        self.remotePath = remotePath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    func start() async throws {
        let sftp = sftpBridge
        let basePath = remotePath

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(WebDAVHandler(sftpBridge: sftp, basePath: basePath))
                }
            }
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = ch
        self.port = ch.localAddress?.port ?? 0
    }

    func stop() async throws {
        try await channel?.close()
        try await group.shutdownGracefully()
    }
}

// MARK: - WebDAV HTTP Handler

private final class WebDAVHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let sftpBridge: SFTPBridge
    let basePath: String

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(sftpBridge: SFTPBridge, basePath: String) {
        self.sftpBridge = sftpBridge
        self.basePath = basePath
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else { return }
            let body = requestBody
            let channel = context.channel
            let sftp = sftpBridge
            let base = basePath
            let uri = head.uri.removingPercentEncoding ?? head.uri
            let remotePath = base == "/" ? uri : base + uri
            let depth = head.headers.first(name: "Depth") ?? "infinity"
            let headers = head.headers

            Task {
                await Self.handleRequest(
                    method: head.method.rawValue,
                    uri: uri,
                    remotePath: remotePath,
                    depth: depth,
                    headers: headers,
                    body: body,
                    sftp: sftp,
                    channel: channel
                )
            }

            requestHead = nil
            requestBody = nil
        }
    }

    // MARK: - Request Dispatch

    static func handleRequest(
        method: String,
        uri: String,
        remotePath: String,
        depth: String,
        headers: HTTPHeaders,
        body: ByteBuffer?,
        sftp: SFTPBridge,
        channel: Channel
    ) async {
        do {
            switch method {
            case "OPTIONS":
                sendResponse(channel: channel, status: .ok, headers: [
                    ("DAV", "1,2"),
                    ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, MOVE, COPY"),
                    ("Content-Length", "0"),
                    ("MS-Author-Via", "DAV"),
                ])

            case "PROPFIND":
                try await handlePropfind(uri: uri, remotePath: remotePath, depth: depth, sftp: sftp, channel: channel)

            case "GET":
                try await handleGet(remotePath: remotePath, sftp: sftp, channel: channel)

            case "HEAD":
                try await handleHead(remotePath: remotePath, sftp: sftp, channel: channel)

            case "PUT":
                try await handlePut(remotePath: remotePath, body: body, sftp: sftp, channel: channel)

            case "DELETE":
                try await handleDelete(remotePath: remotePath, sftp: sftp, channel: channel)

            case "MKCOL":
                try await handleMkcol(remotePath: remotePath, sftp: sftp, channel: channel)

            case "MOVE":
                let dest = headers.first(name: "Destination") ?? ""
                try await handleMove(remotePath: remotePath, destination: dest, sftp: sftp, channel: channel)

            default:
                sendResponse(channel: channel, status: .methodNotAllowed)
            }
        } catch {
            sendResponse(channel: channel, status: .internalServerError, bodyString: error.localizedDescription)
        }
    }

    // MARK: - PROPFIND

    static func handlePropfind(
        uri: String,
        remotePath: String,
        depth: String,
        sftp: SFTPBridge,
        channel: Channel
    ) async throws {
        let entry = try await sftp.stat(at: remotePath)
        var responses = [propfindEntry(uri: uri, entry: entry)]

        if entry.isDirectory && depth != "0" {
            let children = try await sftp.listDirectory(at: remotePath)
            for child in children {
                let childURI = uri.hasSuffix("/") ? uri + child.name : uri + "/" + child.name
                responses.append(propfindEntry(uri: childURI, entry: child))
            }
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """

        sendResponse(
            channel: channel,
            status: .custom(code: 207, reasonPhrase: "Multi-Status"),
            headers: [("Content-Type", "application/xml; charset=utf-8")],
            bodyString: xml
        )
    }

    static func propfindEntry(uri: String, entry: SFTPEntry) -> String {
        let encodedURI = uri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uri
        let resourceType = entry.isDirectory ? "<D:collection/>" : ""
        let rfc1123 = rfc1123Formatter.string(from: entry.modified)

        return """
          <D:response>
            <D:href>\(xmlEscape(encodedURI))</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>\(xmlEscape(entry.name))</D:displayname>
                <D:getcontentlength>\(entry.size)</D:getcontentlength>
                <D:getlastmodified>\(rfc1123)</D:getlastmodified>
                <D:resourcetype>\(resourceType)</D:resourcetype>
                <D:creationdate>\(iso8601Formatter.string(from: entry.modified))</D:creationdate>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        """
    }

    // MARK: - GET

    static func handleGet(remotePath: String, sftp: SFTPBridge, channel: Channel) async throws {
        let data = try await sftp.readFile(at: remotePath)
        sendResponse(
            channel: channel,
            status: .ok,
            headers: [
                ("Content-Type", "application/octet-stream"),
                ("Content-Length", "\(data.count)"),
            ],
            bodyData: data
        )
    }

    // MARK: - HEAD

    static func handleHead(remotePath: String, sftp: SFTPBridge, channel: Channel) async throws {
        let entry = try await sftp.stat(at: remotePath)
        sendResponse(
            channel: channel,
            status: .ok,
            headers: [
                ("Content-Type", entry.isDirectory ? "httpd/unix-directory" : "application/octet-stream"),
                ("Content-Length", "\(entry.size)"),
            ]
        )
    }

    // MARK: - PUT

    static func handlePut(remotePath: String, body: ByteBuffer?, sftp: SFTPBridge, channel: Channel) async throws {
        let data: Data
        if let body, body.readableBytes > 0 {
            data = Data(body.readableBytesView)
        } else {
            data = Data()
        }
        try await sftp.writeFile(at: remotePath, data: data)
        sendResponse(channel: channel, status: .created)
    }

    // MARK: - DELETE

    static func handleDelete(remotePath: String, sftp: SFTPBridge, channel: Channel) async throws {
        let entry = try await sftp.stat(at: remotePath)
        try await sftp.remove(at: remotePath, isDirectory: entry.isDirectory)
        sendResponse(channel: channel, status: .noContent)
    }

    // MARK: - MKCOL

    static func handleMkcol(remotePath: String, sftp: SFTPBridge, channel: Channel) async throws {
        try await sftp.createDirectory(at: remotePath)
        sendResponse(channel: channel, status: .created)
    }

    // MARK: - MOVE

    static func handleMove(remotePath: String, destination: String, sftp: SFTPBridge, channel: Channel) async throws {
        let destPath: String
        if let url = URL(string: destination) {
            destPath = url.path
        } else {
            destPath = destination
        }
        try await sftp.rename(from: remotePath, to: destPath)
        sendResponse(channel: channel, status: .created)
    }

    // MARK: - Response Helpers

    static func sendResponse(
        channel: Channel,
        status: HTTPResponseStatus,
        headers: [(String, String)] = [],
        bodyString: String? = nil,
        bodyData: Data? = nil
    ) {
        let data = bodyData ?? bodyString?.data(using: .utf8)
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        if let data {
            httpHeaders.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
        } else {
            httpHeaders.replaceOrAdd(name: "Content-Length", value: "0")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: httpHeaders)

        channel.eventLoop.execute {
            let headPart = HTTPServerResponsePart.head(head)
            channel.write(NIOAny(headPart), promise: nil)
            if let data, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                let bodyPart = HTTPServerResponsePart.body(.byteBuffer(buffer))
                channel.write(NIOAny(bodyPart), promise: nil)
            }
            let endPart = HTTPServerResponsePart.end(nil)
            channel.writeAndFlush(NIOAny(endPart), promise: nil)
        }
    }

    // MARK: - Utilities

    static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
