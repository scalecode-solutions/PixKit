import Foundation

/// A shared space, as one of its two members sees it.
public struct PixSpace: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The other member.
    public let otherID: UUID
    /// "" until someone names it; the app then shows the other person's name.
    public let name: String
    public let createdBy: UUID
    public let createdAt: Date
    /// nil if never renamed.
    public let renamedAt: Date?

    public init(id: UUID, otherID: UUID, name: String, createdBy: UUID, createdAt: Date, renamedAt: Date?) {
        self.id = id
        self.otherID = otherID
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.renamedAt = renamedAt
    }
}

/// Someone the caller can share a space with (friends both ways).
public struct PixFriend: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// "" when the directory doesn't have them yet.
    public let name: String
    /// A small avatar image, when there is one.
    public let avatar: Data?
    /// The space already shared with them, if any.
    public let spaceID: UUID?

    public init(id: UUID, name: String, avatar: Data?, spaceID: UUID?) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.spaceID = spaceID
    }
}

public enum PixKind: String, Sendable, Hashable, CaseIterable {
    case photo, video, audio
}

/// One photo, video or audio clip in a space. Its bytes are at
/// `/v1/blobs/items/{id}`; its thumbnail, when `hasThumb`, at `…/{id}/thumb`.
public struct PixItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let spaceID: UUID
    /// Who added it (only they can delete it).
    public let uploaderID: UUID
    public let kind: PixKind
    public let mimeType: String
    /// Bytes of the stored file.
    public let size: Int64
    /// 0 when not known.
    public let width: Int
    public let height: Int
    /// nil for photos.
    public let duration: Duration?
    public let createdAt: Date
    /// Audio has no thumbnail.
    public let hasThumb: Bool

    public init(id: UUID, spaceID: UUID, uploaderID: UUID, kind: PixKind, mimeType: String, size: Int64,
                width: Int, height: Int, duration: Duration?, createdAt: Date, hasThumb: Bool) {
        self.id = id
        self.spaceID = spaceID
        self.uploaderID = uploaderID
        self.kind = kind
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.createdAt = createdAt
        self.hasThumb = hasThumb
    }
}

/// One page of a space's items, newest first.
public struct PixItemPage: Sendable, Hashable {
    public let items: [PixItem]
    /// nil on the last page.
    public let nextPageToken: String?

    public init(items: [PixItem], nextPageToken: String?) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}
