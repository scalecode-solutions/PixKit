import SwiftUI

/// What the host knows about people, for a host that has its own names and
/// photos (a nickname, a contact photo) so a space reads the same as the rest
/// of the host. Every field is optional: nil, or no answer for an id, uses the
/// kit's own data from mvPix, exactly as without a host.
///
/// The closures run while a view draws, on the main actor. A host that reads
/// its own observable state inside them keeps open screens live: a rename or
/// a new photo redraws them. Nothing here is ever sent to mvPix.
///
/// PixKit reads `name` and `avatar`. `shortName` and `presence` are part of
/// the shape every kit shares; PixKit ignores them.
public struct PixHostPeople: Sendable {
    let name: @MainActor @Sendable (UUID) -> String?
    let shortName: @MainActor @Sendable (UUID) -> String?
    let avatar: @MainActor @Sendable (UUID, CGFloat) -> AnyView?
    let presence: @MainActor @Sendable (UUID) -> PixHostPresence?

    /// - Parameters:
    ///   - name: the person's name as the host shows it (already formatted).
    ///   - shortName: a short form for tight spots (ignored by PixKit).
    ///   - avatar: the host draws the person's photo at that size itself (its
    ///     own image and cache); the kit never handles the image.
    ///   - presence: what the host shows for the person now (ignored by PixKit).
    public init(name: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                shortName: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                avatar: @escaping @MainActor @Sendable (UUID, CGFloat) -> AnyView? = { _, _ in nil },
                presence: @escaping @MainActor @Sendable (UUID) -> PixHostPresence? = { _ in nil }) {
        self.name = name
        self.shortName = shortName
        self.avatar = avatar
        self.presence = presence
    }

    /// No host: the kit's own names and photos.
    public static let none = PixHostPeople()
}

/// What the host shows for a person's presence (part of the shared shape;
/// PixKit doesn't display it).
public enum PixHostPresence: Sendable, Equatable {
    /// In the app, in front.
    case active
    /// Connected with the app in the background.
    case background
    /// Away, last seen at a time (nil: unknown).
    case lastSeen(Date?)
}

extension EnvironmentValues {
    @Entry var pixHostPeople: PixHostPeople = .none
}

public extension View {
    /// Show people in PixKit's views as the host does. See `PixHostPeople`.
    func pixHostPeople(_ people: PixHostPeople) -> some View {
        environment(\.pixHostPeople, people)
    }
}

/// The names a view shows: the host's, else mvPix's, else a neutral word.
/// A space's own name, set by its members, always wins over a person's.
@MainActor
struct PixPeople {
    let host: PixHostPeople
    let engine: PixEngine

    /// The person's name, or "" when neither the host nor mvPix has one.
    func name(_ id: UUID) -> String {
        if let n = host.name(id), !n.isEmpty { return n }
        return engine.friend(id)?.name ?? ""
    }

    /// What to call a space: its own name, else the other person's, else
    /// "Shared space".
    func title(of space: PixSpace) -> String {
        if !space.name.isEmpty { return space.name }
        let other = name(space.otherID)
        return other.isEmpty ? String(localized: "Shared space") : other
    }
}
