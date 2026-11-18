import Foundation

// The bytes seams (MVCALE-88, agreed in #mvcalendar r46075/r46100/r46114):
// the uploader owns the bytes, the journal and resume; the engine owns the
// queue rows the UI shows and mirrors them from one `events()` stream; the
// cache owns files on disk. Implementations: PixUploader, PixMediaCache.

/// A queued upload's local id (stable across relaunches; the server's
/// upload id is separate and may change if an expired upload restarts).
public typealias PixUploadID = UUID

public protocol PixUploading: Sendable {
    /// Queues a file for a space. The file is first taken into the kit's own
    /// folder (moved when `ownsFile`, so a recording never lingers in tmp;
    /// copied otherwise), so a kill or relaunch can't lose it, and that
    /// staged copy is deleted the moment the job ends, however it ends.
    /// `mimeType` is what the server sorts by (PixKind(mimeType:)).
    func enqueue(file: URL, mimeType: String, spaceID: UUID, ownsFile: Bool) async throws -> PixUploadID
    /// Every job's events from the moment of the call, one stream for all.
    func events() -> AsyncStream<PixUploadEvent>
    /// Stops a job and drops its staged file. The server's half-upload is
    /// left to its reaper (there is no delete route). Emits `.cancelled`.
    func cancel(_ id: PixUploadID) async
    /// Reads the journal after launch, restarts what it finds, and returns
    /// each job's current state (`.queued`) so the engine can show them.
    func resumeOnLaunch() async -> [PixUploadEvent]
    /// The space is gone (NotFound / unfriended): its jobs are cancelled.
    func forgetSpace(_ spaceID: UUID) async
    /// Sign-out: every job is cancelled and the journal removed.
    func wipeAll() async
}

public struct PixUploadEvent: Sendable, Equatable {
    public let id: PixUploadID
    public let spaceID: UUID
    public let mimeType: String
    /// Bytes of the file being sent.
    public let size: Int64
    /// The server's upload id, once it has one.
    public let uploadID: UUID?
    public let state: PixUploadState

    public init(id: PixUploadID, spaceID: UUID, mimeType: String, size: Int64, uploadID: UUID?, state: PixUploadState) {
        self.id = id
        self.spaceID = spaceID
        self.mimeType = mimeType
        self.size = size
        self.uploadID = uploadID
        self.state = state
    }
}

public enum PixUploadState: Sendable, Equatable {
    case queued
    case uploading(sent: Int64, total: Int64)
    /// The connection or server failed; it tries again by itself.
    case waiting(attempt: Int)
    /// Every byte is in; the server is checking and storing it.
    case processing
    /// `.existing`/`.restored` mean the item was already in the space (a
    /// re-add returns it): upsert by item id, don't append.
    case completed(itemID: UUID, outcome: PixUploadOutcome)
    case failed(PixUploadFailure)
    case cancelled

    /// No more events follow for this job.
    public var isFinal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// How the server settled an upload.
public enum PixUploadOutcome: String, Sendable, Equatable, Decodable {
    /// A new item.
    case added
    /// The uploader already had this exact file in this space: that item.
    case existing
    /// As existing, but it had been deleted and is back.
    case restored
    /// The uploader has it in another space: a new item here, no second copy.
    case reused
}

public enum PixUploadFailure: Sendable, Equatable {
    /// SPACE_NOT_FOUND: the space is gone or no longer shared with us.
    case spaceGone
    /// Over the server's size limit.
    case tooLarge
    /// Not a photo, video or audio type the server takes.
    case unsupported
    /// The server couldn't read it as what it claims to be.
    case unreadable
    /// Longer than the server allows.
    case tooLong
    /// The staged file vanished.
    case fileMissing
    /// Any other refusal: the server's reason and message.
    case refused(reason: String, message: String)
}

/// Files on disk for items and thumbnails: Caches/PixKit/<account>/<space>/<item>[.thumb].
public protocol PixMediaCaching: Sendable {
    /// The cached file if it's on disk, without asking the server.
    func cached(item: UUID, spaceID: UUID, thumb: Bool) async -> URL?
    /// From disk, or downloaded once (concurrent asks share one download).
    /// ITEM_NOT_FOUND drops the item's files and throws `.notFound`.
    func file(item: UUID, spaceID: UUID, thumb: Bool) async throws -> URL
    /// Drops one item's files (deleted).
    func forget(item: UUID, spaceID: UUID) async
    /// Drops everything for a space (unfriended, NotFound).
    func wipe(spaceID: UUID) async
    /// Drops everything for the account (sign-out).
    func wipeAll() async
}

extension PixKind {
    /// The kind the server gives this MIME type (mvPix media.KindOf), or nil
    /// when the server won't take it.
    public init?(mimeType: String) {
        switch mimeType.trimmingCharacters(in: .whitespaces).lowercased() {
        case "image/jpeg", "image/png", "image/heic", "image/heif": self = .photo
        case "video/mp4", "video/quicktime": self = .video
        case "audio/mp4", "audio/x-m4a", "audio/aac", "audio/mpeg": self = .audio
        default: return nil
        }
    }
}
