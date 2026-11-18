import Foundation
import Synchronization

/// One uploader and one cache per account, storage folder and server, for
/// the life of the process (PixUploader.shared, PixMediaCache.shared).
enum PixShared {
    static let uploaders = Registry<PixUploader>()
    static let caches = Registry<PixMediaCache>()

    final class Registry<T: AnyObject & Sendable>: Sendable {
        private struct Entry { let object: T; let token: TokenBox }
        private let entries = Mutex<[String: Entry]>([:])

        /// The instance for `config`, made once with a token provider that
        /// always asks the latest config's.
        func instance(for config: PixConfig, make: (@escaping PixBlobClient.TokenProvider) -> T) -> T {
            let key = [config.currentUserID.uuidString.lowercased(),
                       config.storageDirectory?.standardizedFileURL.path ?? "-",
                       config.baseURL.absoluteString].joined(separator: "|")
            return entries.withLock { map in
                if let e = map[key] {
                    e.token.set(config.tokenProvider)
                    return e.object
                }
                let box = TokenBox(config.tokenProvider)
                let object = make { await box.get()() }
                map[key] = Entry(object: object, token: box)
                return object
            }
        }

        var count: Int { entries.withLock { $0.count } }
    }

    final class TokenBox: Sendable {
        private let provider: Mutex<PixBlobClient.TokenProvider>
        init(_ p: @escaping PixBlobClient.TokenProvider) { provider = Mutex(p) }
        func set(_ p: @escaping PixBlobClient.TokenProvider) { provider.withLock { $0 = p } }
        func get() -> PixBlobClient.TokenProvider { provider.withLock { $0 } }
    }
}
