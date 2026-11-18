import Foundation
import Synchronization

extension PixUploadFailure {
    static func from(_ err: PixBlobError) -> PixUploadFailure {
        switch err {
        case .noToken: return .refused(reason: "UNAUTHENTICATED", message: "signed out")
        case .transport(let m): return .refused(reason: "TRANSPORT", message: m)
        case .server(let e):
            switch e.reason {
            case "SPACE_NOT_FOUND": return .spaceGone
            case "UPLOAD_TOO_LARGE", "SIZE_EXCEEDED": return .tooLarge
            case "UNSUPPORTED_MEDIA_TYPE", "INVALID_MIME_TYPE": return .unsupported
            case "MEDIA_UNREADABLE": return .unreadable
            case "MEDIA_TOO_LONG": return .tooLong
            default: return .refused(reason: e.reason.isEmpty ? e.code : e.reason, message: e.message)
            }
        }
    }
}

// MARK: - The uploader

/// Uploads one file at a time, in the order queued, through the resumable
/// byte routes. Each job lives in Application Support/PixKit/<account>/
/// uploads/<local id>/ as `job.json` plus the staged file (excluded from
/// backup), and is removed the moment the job ends, whatever the ending:
/// nothing staged outlives its upload.
///
/// Resume: the journal keeps the server's upload id; after a kill the job
/// asks the server how much it has (GET status) and sends the rest. An
/// upload the server no longer knows (expired, reaped) starts over from the
/// first byte. Complete is idempotent on the server, so a lost answer is
/// simply asked again.
public actor PixUploader: PixUploading {
    struct Record: Codable, Equatable {
        var id: UUID
        var spaceID: UUID
        var mimeType: String
        var size: Int64
        var fileName: String
        var createdAt: Date
        var uploadID: UUID?
        var chunkSize: Int64?
        var chunkAlignment: Int64?
    }

    public nonisolated let folder: URL
    private let client: PixBlobClient
    /// Backoff between tries after a transport failure; tests shorten it.
    private let backoff: @Sendable (Int) -> Duration

    private var order: [UUID] = []
    private var records: [UUID: Record] = [:]
    private var last: [UUID: PixUploadEvent] = [:]
    /// Read from the nonisolated `events()`, so behind a lock.
    private nonisolated let listeners = Listeners()
    private var runner: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Attempt, Never>)?
    /// Per job, in memory: when it's due again, its tries since it last
    /// made progress, how many of those the server refused, and whether its
    /// upload has been restarted once already.
    private var due: [UUID: ContinuousClock.Instant] = [:]
    private var tries: [UUID: Int] = [:]
    private var serverFailures: [UUID: Int] = [:]
    private var restarted: Set<UUID> = []
    private var idle: Task<Void, Never>?

    public init(config: PixConfig) {
        self.init(account: config.currentUserID, client: PixBlobClient(config: config), base: config.storageDirectory)
    }

    init(account: UUID, client: PixBlobClient, base: URL? = nil,
                backoff: @escaping @Sendable (Int) -> Duration = { .seconds(min(60, 1 << min($0, 6))) }) {
        let support = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = support
            .appending(path: "PixKit", directoryHint: .isDirectory)
            .appending(path: account.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "uploads", directoryHint: .isDirectory)
        self.client = client
        self.backoff = backoff
    }

    // MARK: PixUploading

    public func enqueue(file: URL, mimeType: String, spaceID space: UUID, ownsFile: Bool) async throws -> PixUploadID {
        let fm = FileManager.default
        let id = UUID()
        let dir = jobDir(id)
        let name = "file" + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
        let staged = dir.appending(path: name)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = folder
            try? excluded.setResourceValues(values)
            if ownsFile { try fm.moveItem(at: file, to: staged) } else { try fm.copyItem(at: file, to: staged) }
            let size = (try fm.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? 0
            let rec = Record(id: id, spaceID: space, mimeType: mimeType, size: size,
                             fileName: name, createdAt: Date(), uploadID: nil, chunkSize: nil, chunkAlignment: nil)
            try save(rec)
            records[id] = rec
            order.append(id)
        } catch {
            try? fm.removeItem(at: dir)
            if ownsFile { try? fm.removeItem(at: file) }
            throw error
        }
        emit(id, .queued)
        kick()
        return id
    }

    public nonisolated func events() -> AsyncStream<PixUploadEvent> {
        listeners.add()
    }

    public func cancel(_ id: UUID) {
        guard records[id] != nil else { return }
        finish(id, .cancelled)
    }

    public func resumeOnLaunch() -> [PixUploadEvent] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [Record] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appending(path: "job.json")),
                  let rec = try? JSONDecoder().decode(Record.self, from: data),
                  dir.lastPathComponent == rec.id.uuidString.lowercased() else {
                try? fm.removeItem(at: dir) // half-written or foreign: never kept
                continue
            }
            if records[rec.id] == nil { found.append(rec) }
        }
        found.sort { $0.createdAt < $1.createdAt }
        for rec in found {
            records[rec.id] = rec
            order.append(rec.id)
            emit(rec.id, .queued)
        }
        kick()
        return found.map { event($0, .queued) }
    }

    public func forgetSpace(_ space: UUID) {
        for id in order where records[id]?.spaceID == space {
            finish(id, .cancelled)
        }
    }

    public func wipeAll() {
        for id in order { finish(id, .cancelled) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The jobs not yet finished, in order, as their latest events.
    public func jobs() -> [PixUploadEvent] { order.compactMap { last[$0] } }

    // MARK: Running

    /// How many times the server may answer a job with a failure worth
    /// retrying (5xx, 429, 408, 401) before the job fails. Tries that got no
    /// answer at all (the network, or no token yet) don't count: they're
    /// about the device, not the job.
    static let maxServerFailures = 8

    private func kick() {
        if runner == nil {
            runner = Task { await self.drain() }
        } else {
            idle?.cancel() // a new or resumed job: stop waiting on the backoff
        }
    }

    /// Runs one try of the first job that's due, in queue order. A job that
    /// has to wait goes to the back with a time it's due again, so one job
    /// the server keeps failing never holds up the jobs behind it.
    private func drain() async {
        while true {
            let now = ContinuousClock.now
            let live = order.filter { records[$0] != nil }
            if live.isEmpty { break }
            guard let id = live.first(where: { (due[$0] ?? now) <= now }) else {
                let next = live.compactMap { due[$0] }.min() ?? now
                let sleeper = Task { _ = try? await Task.sleep(until: next, clock: .continuous) }
                idle = sleeper
                await sleeper.value
                idle = nil
                continue
            }
            let task = Task { await self.attempt(id) }
            current = (id, task)
            let outcome = await task.value
            current = nil
            guard records[id] != nil else { continue } // finished (or cancelled from outside)
            switch outcome {
            case .ended:
                // A try that returned without finishing is never left hanging.
                if last[id]?.state.isFinal != true {
                    finish(id, .failed(.refused(reason: "STOPPED", message: "upload stopped")))
                }
            case .retry(let err, let answered):
                tries[id, default: 0] += 1
                if answered {
                    serverFailures[id, default: 0] += 1
                    if serverFailures[id]! >= Self.maxServerFailures {
                        finish(id, .failed(.from(err)))
                        continue
                    }
                }
                let n = tries[id]!
                emit(id, .waiting(attempt: n))
                due[id] = ContinuousClock.now + backoff(n)
                order.removeAll { $0 == id }
                order.append(id)
            }
        }
        runner = nil
    }

    enum Attempt: Sendable {
        /// The job finished (or was stopped from outside).
        case ended
        /// Try again later; `answered` when the server itself said no.
        case retry(PixBlobError, answered: Bool)
    }

    /// One try at a job: from wherever the server is, to complete.
    private func attempt(_ id: UUID) async -> Attempt {
        while !Task.isCancelled, var rec = records[id] {
            do {
                let file = jobDir(id).appending(path: rec.fileName)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    finish(id, .failed(.fileMissing))
                    return .ended
                }

                // 1. A server upload, new or resumed.
                var offset: Int64 = 0
                if let up = rec.uploadID {
                    let st = try await client.status(upload: up)
                    rec.chunkSize = st.chunkSize
                    offset = st.received
                    if st.completed || st.complete {
                        offset = rec.size
                    }
                } else {
                    let s = try await client.initUpload(space: rec.spaceID, mimeType: rec.mimeType, size: rec.size)
                    rec.uploadID = s.uploadId
                    rec.chunkSize = s.chunkSize
                    rec.chunkAlignment = s.chunkAlignment
                    guard records[id] != nil else { return .ended } // cancelled meanwhile
                    try save(rec)
                    records[id] = rec
                }
                guard let up = rec.uploadID, let chunk = rec.chunkSize, chunk > 0 else {
                    throw PixBlobError.transport("no upload session")
                }

                // 2. The bytes, one part at a time from the server's offset.
                emit(id, .uploading(sent: offset, total: rec.size))
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while offset < rec.size {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(offset))
                    let n = Int(min(chunk, rec.size - offset))
                    guard let bytes = try handle.read(upToCount: n), bytes.count == n else {
                        finish(id, .failed(.fileMissing))
                        return .ended
                    }
                    do {
                        let st = try await client.put(upload: up, offset: offset, bytes: bytes)
                        offset = st.received
                    } catch let err as PixBlobError where err.reason == "OFFSET_MISMATCH" || err.reason == "UPLOAD_BUSY" {
                        // The server is the authority on where we are.
                        if err.reason == "UPLOAD_BUSY" { try await Task.sleep(for: .seconds(1)) }
                        if case .server(let e) = err, let o = e.uploadOffset { offset = o }
                        else { offset = try await client.status(upload: up).received }
                    } catch let err as PixBlobError where err.reason == "UPLOAD_COMPLETED" {
                        offset = rec.size
                    }
                    // Progress resets the count: a job that moves isn't stuck.
                    tries[id] = nil
                    serverFailures[id] = nil
                    emit(id, .uploading(sent: offset, total: rec.size))
                }

                // 3. Settle.
                emit(id, .processing)
                let done = try await completeRetryingBusy(up)
                finish(id, .completed(itemID: done.itemId, outcome: done.status))
                return .ended

            } catch is CancellationError {
                return .ended
            } catch let err as PixBlobError {
                if err.reason == "UPLOAD_NOT_FOUND", !restarted.contains(id) {
                    // Expired or reaped: start over once, from the first byte.
                    restarted.insert(id)
                    rec.uploadID = nil
                    rec.chunkSize = nil
                    guard records[id] != nil else { return .ended }
                    try? save(rec)
                    records[id] = rec
                    continue
                }
                if Self.retryable(err) {
                    return .retry(err, answered: Self.serverAnswered(err))
                }
                finish(id, .failed(.from(err)))
                return .ended
            } catch let err as URLError where err.code != .cancelled {
                return .retry(.transport(err.localizedDescription), answered: false)
            } catch {
                if Task.isCancelled { return .ended }
                finish(id, .failed(.refused(reason: "CLIENT", message: error.localizedDescription)))
                return .ended
            }
        }
        return .ended
    }

    /// Worth another try by itself: no answer, the server or proxy failing,
    /// rate limiting, or an expired token (the provider refreshes it).
    static func retryable(_ err: PixBlobError) -> Bool {
        guard let status = err.status else { return true }
        return status >= 500 || status == 429 || status == 408 || status == 401
    }

    /// The server itself refused (counts toward maxServerFailures), as
    /// opposed to no answer or no token on the device.
    static func serverAnswered(_ err: PixBlobError) -> Bool {
        if case .server = err { return true }
        return false
    }

    /// Complete, asked again while another complete of ours (a lost answer)
    /// is still processing: the server bounds that at 10 minutes.
    private func completeRetryingBusy(_ up: UUID) async throws -> PixBlobClient.Completed {
        var busy = 0
        while true {
            do { return try await client.complete(upload: up) } catch let err as PixBlobError where err.reason == "UPLOAD_BUSY" {
                busy += 1
                if busy > 330 { throw err } // ~11 minutes: past the server's bound
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: State

    /// Ends a job: its event, its folder, its record. Called exactly once
    /// per job; a running job's task is cancelled.
    private func finish(_ id: UUID, _ state: PixUploadState) {
        guard records[id] != nil else { return }
        emit(id, state)
        records[id] = nil
        order.removeAll { $0 == id }
        last[id] = nil
        due[id] = nil
        tries[id] = nil
        serverFailures[id] = nil
        restarted.remove(id)
        if let current, current.id == id { current.task.cancel() }
        try? FileManager.default.removeItem(at: jobDir(id))
    }

    private func emit(_ id: UUID, _ state: PixUploadState) {
        guard let rec = records[id] else { return }
        let e = event(rec, state)
        last[id] = e
        listeners.yield(e)
    }

    private func event(_ r: Record, _ state: PixUploadState) -> PixUploadEvent {
        PixUploadEvent(id: r.id, spaceID: r.spaceID, mimeType: r.mimeType, size: r.size, uploadID: r.uploadID, state: state)
    }

    private func jobDir(_ id: UUID) -> URL { folder.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory) }

    private func save(_ rec: Record) throws {
        let data = try JSONEncoder().encode(rec)
        try data.write(to: jobDir(rec.id).appending(path: "job.json"), options: .atomic)
    }
}

/// The event fan-out: each `events()` call gets its own stream; a stream
/// whose consumer goes away is dropped.
final class Listeners: Sendable {
    private let state = Mutex<[UUID: AsyncStream<PixUploadEvent>.Continuation]>([:])

    func add() -> AsyncStream<PixUploadEvent> {
        let key = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: PixUploadEvent.self, bufferingPolicy: .unbounded)
        state.withLock { $0[key] = cont }
        cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.removeValue(forKey: key) } }
        return stream
    }

    func yield(_ e: PixUploadEvent) {
        for c in state.withLock({ Array($0.values) }) { c.yield(e) }
    }
}
