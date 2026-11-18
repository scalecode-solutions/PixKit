import Foundation

/// The byte routes under /v1/blobs/: resumable upload and item downloads.
/// Plain URLSession (the metadata goes through Connect; bytes don't).
///
///     POST /v1/blobs/uploads                 {"spaceId","mimeType","size"} → 201
///     PUT  /v1/blobs/uploads/{id}?offset=N   raw bytes, Content-Length → 200
///     GET  /v1/blobs/uploads/{id}            → 200, the authoritative offset
///     POST /v1/blobs/uploads/{id}/complete   → 201/200 {itemId, status}
///     GET  /v1/blobs/items/{id}[/thumb]      whole (200) or one range (206)
struct PixBlobClient: Sendable {
    typealias TokenProvider = @Sendable () async -> String?

    let baseURL: URL
    let token: TokenProvider
    let session: URLSession

    init(config: PixConfig, session: URLSession = .shared) {
        self.init(baseURL: config.baseURL, token: config.tokenProvider, session: session)
    }

    init(baseURL: URL, token: @escaping TokenProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Upload

    public struct Session: Sendable, Equatable, Decodable {
        public let uploadId: UUID
        public let totalSize: Int64
        public let chunkSize: Int64
        public let chunkAlignment: Int64
        /// Unix milliseconds.
        public let expiresAt: Int64
    }

    public struct Status: Sendable, Equatable, Decodable {
        public let uploadId: UUID
        public let received: Int64
        public let totalSize: Int64
        /// Every byte is in.
        public let complete: Bool
        /// Settled by complete.
        public let completed: Bool
        public let chunkSize: Int64
        public let expiresAt: Int64?
    }

    public struct Completed: Sendable, Equatable, Decodable {
        public let uploadId: UUID
        public let itemId: UUID
        public let status: PixUploadOutcome
    }

    public func initUpload(space: UUID, mimeType: String, size: Int64) async throws -> Session {
        struct Body: Encodable { let spaceId: String; let mimeType: String; let size: Int64 }
        var req = try await request("POST", path: "v1/blobs/uploads")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(spaceId: space.uuidString.lowercased(), mimeType: mimeType, size: size))
        return try await decode(Session.self, send(req, expect: [201]))
    }

    /// Sends one part. The server takes a whole number of `chunkAlignment`
    /// bytes up to `chunkSize`, unless the part ends the file.
    public func put(upload: UUID, offset: Int64, bytes: Data) async throws -> Status {
        var req = try await request("PUT", path: "v1/blobs/uploads/\(upload.uuidString.lowercased())",
                                    query: [URLQueryItem(name: "offset", value: String(offset))])
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = bytes
        return try await decode(Status.self, send(req, expect: [200]))
    }

    public func status(upload: UUID) async throws -> Status {
        let req = try await request("GET", path: "v1/blobs/uploads/\(upload.uuidString.lowercased())")
        return try await decode(Status.self, send(req, expect: [200]))
    }

    /// Settles the upload. Processing a long video can take minutes, so the
    /// request's timeout is the server's own bound plus a margin.
    public func complete(upload: UUID) async throws -> Completed {
        var req = try await request("POST", path: "v1/blobs/uploads/\(upload.uuidString.lowercased())/complete")
        req.timeoutInterval = 11 * 60
        return try await decode(Completed.self, send(req, expect: [200, 201]))
    }

    // MARK: Download

    /// Downloads an item (or its thumbnail) to `destination`, writing as the
    /// bytes arrive into `destination.part` beside an `.etag` file. A try cut
    /// off midway leaves both behind, and the next try asks only for the rest
    /// (Range + If-Range): a file that changed since comes back whole (200)
    /// and replaces the part instead of being spliced onto it.
    public func download(item: UUID, thumb: Bool, to destination: URL) async throws {
        let fm = FileManager.default
        let part = destination.appendingPathExtension("part")
        let etagFile = destination.appendingPathExtension("etag")
        var path = "v1/blobs/items/\(item.uuidString.lowercased())"
        if thumb { path += "/thumb" }
        var req = try await request("GET", path: path)

        var have: Int64 = 0
        if let etag = try? String(contentsOf: etagFile, encoding: .utf8), !etag.isEmpty,
           let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64, size > 0 {
            have = size
            req.setValue("bytes=\(size)-", forHTTPHeaderField: "Range")
            req.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let sink = DownloadSink(part: part, etagFile: etagFile, resumeAt: have)
        let delegateSession = URLSession(configuration: session.configuration, delegate: sink, delegateQueue: nil)
        defer { delegateSession.finishTasksAndInvalidate() }
        let result = try await sink.run(req, in: delegateSession)

        guard (200...299).contains(result.status) else {
            if result.status == 416 {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: etagFile)
            }
            throw PixBlobError.from(status: result.status, body: result.errorBody)
        }
        let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? -1
        if let expected = result.expectedTotal, size != expected {
            throw PixBlobError.transport("short download")
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
        try? fm.removeItem(at: etagFile)
    }

    static func totalFromContentRange(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...])
    }

    // MARK: Plumbing

    func request(_ method: String, path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        guard let t = await token(), !t.isEmpty else { throw PixBlobError.noToken }
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        return req
    }

    func send(_ req: URLRequest, expect: Set<Int>) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        return try check(data, resp, expect: expect)
    }

    func check(_ data: Data, _ resp: URLResponse, expect: Set<Int>) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { throw PixBlobError.transport("no HTTP response") }
        guard expect.contains(http.statusCode) else {
            var err = PixBlobError.from(status: http.statusCode, body: data)
            if case .server(var e) = err, let off = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) {
                e.uploadOffset = off
                err = .server(e)
            }
            throw err
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw PixBlobError.transport("bad response body")
        }
    }
}

/// An answer from the byte routes that isn't the one asked for.
enum PixBlobError: Error, Sendable, Equatable {
    /// The server's envelope: {"error":{"code","reason","message"}}.
    case server(ServerError)
    /// No usable answer (connection, malformed body, short download).
    case transport(String)
    /// The host has no token right now (signed out, or refreshing).
    case noToken

    public struct ServerError: Sendable, Equatable {
        public let status: Int
        public let code: String
        public let reason: String
        public let message: String
        /// The authoritative resume offset, when a PUT error carried one.
        public var uploadOffset: Int64?
    }

    public var reason: String? {
        if case .server(let e) = self { return e.reason }
        return nil
    }

    public var status: Int? {
        switch self {
        case .server(let e): e.status
        case .noToken: 401
        case .transport: nil
        }
    }

    /// The transport's view of it, for callers outside the bytes code.
    var transportError: PixTransportError {
        switch self {
        case .noToken: return .notAuthenticated
        case .transport(let m): return .unavailable(m)
        case .server(let e):
            switch e.status {
            case 401: return .notAuthenticated
            case 403: return .forbidden(e.message)
            case 404: return .notFound
            case 429: return .slowDown
            case 400, 409, 412, 413, 415, 416, 422: return .invalid(e.message)
            case 502, 503, 504: return .unavailable(e.message)
            default: return .serverFailed(e.message)
            }
        }
    }

    static func from(status: Int, body: Data) -> PixBlobError {
        struct Envelope: Decodable {
            struct E: Decodable { let code: String; let reason: String?; let message: String? }
            let error: E
        }
        let e = try? JSONDecoder().decode(Envelope.self, from: body)
        return .server(ServerError(status: status, code: e?.error.code ?? "HTTP_\(status)",
                                   reason: e?.error.reason ?? "", message: e?.error.message ?? "",
                                   uploadOffset: nil))
    }
}

/// Writes one download's body to disk as it arrives. On 206 it appends to
/// the part; on 200 it truncates and starts over; anything else is an error
/// whose (small) body is kept for the envelope.
final class DownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { var status: Int; var expectedTotal: Int64?; var errorBody: Data }

    private let part: URL
    private let etagFile: URL
    private let resumeAt: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var result = Result(status: 0, expectedTotal: nil, errorBody: Data())
    private var failure: Error?
    private var continuation: CheckedContinuation<Result, Error>?

    init(part: URL, etagFile: URL, resumeAt: Int64) {
        self.part = part
        self.etagFile = etagFile
        self.resumeAt = resumeAt
    }

    func run(_ req: URLRequest, in session: URLSession) async throws -> Result {
        let task = session.dataTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.withLock { continuation = cont }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            guard let http = response as? HTTPURLResponse else {
                failure = PixBlobError.transport("no HTTP response")
                completionHandler(.cancel)
                return
            }
            result.status = http.statusCode
            do {
                switch http.statusCode {
                case 206:
                    let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard resumeAt > 0, range.hasPrefix("bytes \(resumeAt)-") else {
                        throw PixBlobError.transport("unexpected Content-Range")
                    }
                    result.expectedTotal = PixBlobClient.totalFromContentRange(range)
                    let h = try FileHandle(forWritingTo: part)
                    try h.seekToEnd()
                    handle = h
                case 200:
                    let fm = FileManager.default
                    try? fm.removeItem(at: part)
                    fm.createFile(atPath: part.path, contents: nil)
                    if let etag = http.value(forHTTPHeaderField: "ETag") {
                        try etag.write(to: etagFile, atomically: true, encoding: .utf8)
                    } else {
                        try? fm.removeItem(at: etagFile)
                    }
                    if http.expectedContentLength >= 0 { result.expectedTotal = http.expectedContentLength }
                    handle = try FileHandle(forWritingTo: part)
                default:
                    break
                }
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard failure == nil else { return }
            if let handle {
                do { try handle.write(contentsOf: data) } catch {
                    failure = error
                    dataTask.cancel()
                }
            } else if result.errorBody.count < 4096 {
                result.errorBody.append(data.prefix(4096 - result.errorBody.count))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, outcome): (CheckedContinuation<Result, Error>?, Swift.Result<Result, Error>) = lock.withLock {
            try? handle?.close()
            handle = nil
            let c = continuation
            continuation = nil
            if let failure { return (c, .failure(failure)) }
            if let error { return (c, .failure(error)) }
            return (c, .success(result))
        }
        cont?.resume(with: outcome)
    }
}
