import Foundation
import Testing
@testable import PixKit

/// Shared bits for the bytes tests: a temp folder per test, a file of N
/// known bytes, and waiting on an upload's events.
struct BytesFixture {
    let dir: URL
    let account = UUID()
    let space = UUID()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pixkit-bytes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func file(_ n: Int, name: String = UUID().uuidString + ".jpg") throws -> (URL, Data) {
        let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = dir.appending(path: name)
        try data.write(to: url)
        return (url, data)
    }

    func uploader(_ server: FakeBlobServer, base: URL? = nil, backoff: Duration = .milliseconds(5)) -> PixUploader {
        PixUploader(account: account, client: server.client(), base: base ?? dir.appending(path: "support"), backoff: { _ in backoff })
    }

    func cache(_ server: FakeBlobServer) -> PixMediaCache {
        PixMediaCache(account: account, client: server.client(), base: dir.appending(path: "caches"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// Collects every event until `finals` jobs have ended (or a timeout).
func collect(_ stream: AsyncStream<PixUploadEvent>, finals: Int = 1,
             timeout: Duration = .seconds(10)) async -> [PixUploadEvent] {
    await withTaskGroup(of: [PixUploadEvent]?.self) { group in
        group.addTask {
            var out: [PixUploadEvent] = []
            var ended = 0
            for await e in stream {
                out.append(e)
                if e.state.isFinal { ended += 1 }
                if ended >= finals { return out }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

extension Array where Element == PixUploadEvent {
    var states: [PixUploadState] { map(\.state) }
    var final: PixUploadState? { last(where: { $0.state.isFinal })?.state }
}

/// Waits for the first event matching `pred` (false on timeout).
func waitFor(_ stream: AsyncStream<PixUploadEvent>, timeout: Duration = .seconds(10),
             _ pred: @escaping @Sendable (PixUploadEvent) -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await e in stream where pred(e) { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

func isWaiting(_ e: PixUploadEvent) -> Bool { if case .waiting = e.state { true } else { false } }

/// Waits until `cond` holds, polling briefly.
func bytesEventually(_ timeout: Duration = .seconds(5), _ cond: @Sendable () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}
