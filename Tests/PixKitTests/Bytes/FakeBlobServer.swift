import Foundation
@testable import PixKit

/// An in-memory /v1/blobs/ server behind URLProtocol, with the real one's
/// rules: chunk alignment, offsets, Upload-Offset on PUT answers, an
/// idempotent complete, ranges with If-Range. Each test gets its own host,
/// so tests run in parallel without sharing state.
final class FakeBlobServer: @unchecked Sendable {
    struct Upload { var space: UUID; var mime: String; var total: Int64; var data = Data(); var item: UUID? }

    let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
    let lock = NSLock()
    var chunkSize: Int64 = 64
    var alignment: Int64 = 16
    var uploads: [UUID: Upload] = [:]
    var items: [UUID: (data: Data, thumb: Data, etag: String, space: UUID)] = [:]
    var goneSpaces: Set<UUID> = []
    var log: [String] = []
    /// Called before each request; return a status to fail it with, or
    /// throw a URLError to fail the connection.
    var inject: (@Sendable (URLRequest, Int) throws -> Int?)?
    var requestCount = 0
    /// Handle the request, then lose the answer (the server did the work;
    /// the client never hears). Given the request and its number.
    var dropReply: (@Sendable (URLRequest, Int) -> Bool)?
    /// Cut downloads after this many bytes (simulates a dropped connection).
    var cutDownloadAfter: Int?

    var baseURL: URL { URL(string: "https://\(host)/")! }

    init() { FakeBlobServer.register(self) }
    deinit { FakeBlobServer.unregister(host) }

    func client(token: String? = "tok") -> PixBlobClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeProtocol.self]
        return PixBlobClient(baseURL: baseURL, token: { token }, session: URLSession(configuration: cfg))
    }

    func addItem(space: UUID, bytes: Data) -> UUID {
        let id = UUID()
        lock.withLock { items[id] = (bytes, Data("thumb-\(id)".utf8), "\"\(id)\"", space) }
        return id
    }

    // MARK: registry

    nonisolated(unsafe) static var servers: [String: FakeBlobServer] = [:]
    static let regLock = NSLock()
    static func register(_ s: FakeBlobServer) { regLock.withLock { servers[s.host] = s } }
    static func unregister(_ h: String) { _ = regLock.withLock { servers.removeValue(forKey: h) } }
    static func server(for host: String?) -> FakeBlobServer? { regLock.withLock { servers[host ?? ""] } }

    // MARK: handling

    struct Reply { var status: Int; var headers: [String: String] = [:]; var body = Data() }

    func handle(_ req: URLRequest, body: Data) throws -> Reply {
        let n: Int = lock.withLock { requestCount += 1; return requestCount }
        if let inject, let status = try inject(req, n) {
            return err(status, "HTTP_\(status)", "")
        }
        guard req.value(forHTTPHeaderField: "Authorization") == "Bearer tok" else {
            return err(401, "UNAUTHORIZED", "")
        }
        let parts = req.url!.path.split(separator: "/").map(String.init)
        let method = req.httpMethod ?? "GET"
        return lock.withLock {
            log.append("\(method) \(req.url!.path)\(req.url!.query.map { "?" + $0 } ?? "")")
            switch (method, parts.count) {
            case ("POST", 3) where parts == ["v1", "blobs", "uploads"]:
                let j = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                let space = UUID(uuidString: j["spaceId"] as! String)!
                if goneSpaces.contains(space) { return err(404, "NOT_FOUND", "SPACE_NOT_FOUND") }
                let id = UUID()
                uploads[id] = Upload(space: space, mime: j["mimeType"] as! String, total: (j["size"] as! NSNumber).int64Value)
                return json(201, ["uploadId": id.uuidString.lowercased(), "totalSize": uploads[id]!.total,
                                  "chunkSize": chunkSize, "chunkAlignment": alignment, "expiresAt": 0])
            case ("PUT", 4):
                guard let id = UUID(uuidString: parts[3]), var u = uploads[id] else { return err(404, "NOT_FOUND", "UPLOAD_NOT_FOUND") }
                if goneSpaces.contains(u.space) { return err(404, "NOT_FOUND", "SPACE_NOT_FOUND") }
                let off = Int64(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!)!
                let have = Int64(u.data.count)
                if u.item != nil { return err(409, "CONFLICT", "UPLOAD_COMPLETED", offset: have) }
                if off != have { return err(409, "CONFLICT", "OFFSET_MISMATCH", offset: have) }
                let len = Int64(body.count)
                if len > chunkSize { return err(413, "PAYLOAD_TOO_LARGE", "CHUNK_TOO_LARGE", offset: have) }
                if off + len > u.total { return err(400, "BAD_REQUEST", "SIZE_EXCEEDED", offset: have) }
                if off + len < u.total && len % alignment != 0 { return err(400, "BAD_REQUEST", "CHUNK_MISALIGNED", offset: have) }
                u.data.append(body)
                uploads[id] = u
                var r = status(id)
                r.headers["Upload-Offset"] = String(u.data.count)
                return r
            case ("GET", 4) where parts[2] == "uploads":
                guard let id = UUID(uuidString: parts[3]), uploads[id] != nil else { return err(404, "NOT_FOUND", "UPLOAD_NOT_FOUND") }
                return status(id)
            case ("POST", 5) where parts[4] == "complete":
                guard let id = UUID(uuidString: parts[3]), var u = uploads[id] else { return err(404, "NOT_FOUND", "UPLOAD_NOT_FOUND") }
                if Int64(u.data.count) != u.total { return err(412, "PRECONDITION_FAILED", "UPLOAD_INCOMPLETE") }
                if let item = u.item { return json(200, ["uploadId": parts[3], "itemId": item.uuidString.lowercased(), "status": "existing"]) }
                let item = UUID()
                u.item = item
                uploads[id] = u
                items[item] = (u.data, Data("thumb".utf8), "\"\(item)\"", u.space)
                return json(201, ["uploadId": parts[3], "itemId": item.uuidString.lowercased(), "status": "added"])
            case ("GET", 4) where parts[2] == "items", ("GET", 5) where parts[2] == "items":
                guard let id = UUID(uuidString: parts[3]), let it = items[id], !goneSpaces.contains(it.space) else {
                    return err(404, "NOT_FOUND", "ITEM_NOT_FOUND")
                }
                let data = parts.count == 5 ? it.thumb : it.data
                if let range = req.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
                   req.value(forHTTPHeaderField: "If-Range").map({ $0 == it.etag }) ?? true,
                   let start = Int(range.dropFirst(6).dropLast()) {
                    if start >= data.count { return Reply(status: 416, headers: ["Content-Range": "bytes */\(data.count)"]) }
                    return Reply(status: 206, headers: ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)", "ETag": it.etag],
                                 body: data.subdata(in: start..<data.count))
                }
                return Reply(status: 200, headers: ["ETag": it.etag, "Content-Length": String(data.count)], body: data)
            default:
                return err(404, "NOT_FOUND", "")
            }
        }
    }

    private func status(_ id: UUID) -> Reply {
        let u = uploads[id]!
        return json(200, ["uploadId": id.uuidString.lowercased(), "received": u.data.count, "totalSize": u.total,
                          "complete": Int64(u.data.count) == u.total, "completed": u.item != nil, "chunkSize": chunkSize])
    }

    private func json(_ status: Int, _ obj: [String: Any]) -> Reply {
        Reply(status: status, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func err(_ status: Int, _ code: String, _ reason: String, offset: Int64? = nil) -> Reply {
        var r = json(status, ["error": ["code": code, "reason": reason, "message": reason.lowercased()]])
        if let offset { r.headers["Upload-Offset"] = String(offset) }
        return r
    }
}

final class FakeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let server = FakeBlobServer.server(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        do {
            let reply = try server.handle(request, body: body)
            let (drop, n) = server.lock.withLock { (server.dropReply, server.requestCount) }
            if let drop, drop(request, n) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let cut = server.lock.withLock({ server.cutDownloadAfter }), reply.status == 200 || reply.status == 206,
               request.url!.path.contains("/items/"), reply.body.count > cut {
                server.lock.withLock { server.cutDownloadAfter = nil }
                client?.urlProtocol(self, didLoad: reply.body.prefix(cut))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    static func read(_ s: InputStream) -> Data {
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}
