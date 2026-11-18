import SwiftUI

/// Where a space list row leads. Its own type so it can't collide with the
/// host's navigation destinations.
public struct PixSpaceRoute: Hashable, Sendable {
    public let spaceID: UUID
    public init(spaceID: UUID) { self.spaceID = spaceID }
}

/// The person's shared spaces, one per friend, with "new space" and rename.
///
/// **It must sit inside a `NavigationStack`** (a space is pushed onto it).
/// It follows the host's light/dark; it never notifies.
public struct PixSpacesView: View {
    @Bindable var engine: PixEngine
    @State private var picking = false
    @State private var renaming: PixSpace?
    @State private var newName = ""
    @State private var path: PixSpaceRoute?

    public init(engine: PixEngine) {
        self.engine = engine
    }

    public var body: some View {
        content
            .navigationTitle(String(localized: "Spaces"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        picking = true
                    } label: {
                        Label(String(localized: "New space"), systemImage: "plus")
                    }
                    .disabled(engine.spacesState != .loaded)
                    .accessibilityIdentifier("pix.spaces.new")
                }
            }
            .navigationDestination(item: $path) { route in
                PixSpaceView(engine: engine, spaceID: route.spaceID)
            }
            .sheet(isPresented: $picking) {
                NavigationStack {
                    PixFriendPicker(engine: engine) { space in
                        picking = false
                        path = PixSpaceRoute(spaceID: space.id)
                    }
                }
            }
            .alert(String(localized: "Rename space"), isPresented: renameShown) {
                TextField(String(localized: "Name"), text: $newName)
                    .accessibilityIdentifier("pix.rename.field")
                Button(String(localized: "Save")) {
                    guard let s = renaming else { return }
                    let name = newName
                    Task { await engine.rename(s.id, to: name) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Leave it empty to show the other person's name."))
            }
            .pixNotices(engine)
            .task {
                await engine.refresh()
                await engine.startUploads()
            }
            .refreshable { await engine.refresh() }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    @ViewBuilder private var content: some View {
        switch engine.spacesState {
        case .idle, .loading where engine.spaces.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why) where engine.spaces.isEmpty:
            ContentUnavailableView {
                Label(String(localized: "Couldn't load your spaces"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(why)
            } actions: {
                Button(String(localized: "Try again")) { Task { await engine.refresh() } }
            }
            .accessibilityIdentifier("pix.spaces.error")
        default:
            if engine.spaces.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No spaces yet"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(String(localized: "A space is a place to share photos, videos and voice clips with one friend."))
                } actions: {
                    Button(String(localized: "New space")) { picking = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(engine.spaces) { space in
            Button {
                path = PixSpaceRoute(spaceID: space.id)
            } label: {
                PixSpaceRow(engine: engine, space: space)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pix.space.\(space.id.uuidString.lowercased())")
            .contextMenu {
                Button {
                    newName = space.name
                    renaming = space
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    newName = space.name
                    renaming = space
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One space in the list: the other person's avatar, the space's name, and
/// whether something is on its way up.
struct PixSpaceRow: View {
    let engine: PixEngine
    let space: PixSpace

    var body: some View {
        HStack(spacing: 12) {
            PixAvatar(friend: engine.friend(space.otherID), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName(of: space))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !space.name.isEmpty, let other = engine.friend(space.otherID)?.name, !other.isEmpty {
                    Text(String(localized: "With \(other)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            let sending = engine.uploads(in: space.id).filter { !$0.isFailed }.count
            if sending > 0 {
                Label("\(sending)", systemImage: "arrow.up.circle")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(sending) uploading"))
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

/// Friends without a space yet; tapping one opens a space with them.
struct PixFriendPicker: View {
    let engine: PixEngine
    let opened: (PixSpace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var opening: UUID?

    var body: some View {
        Group {
            if engine.friendsWithoutSpace.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Everyone's here"), systemImage: "person.2")
                } description: {
                    Text(engine.friends.isEmpty
                         ? String(localized: "Spaces are for friends. Add a friend first.")
                         : String(localized: "You already share a space with each of your friends."))
                }
            } else {
                List(engine.friendsWithoutSpace.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { friend in
                    Button {
                        opening = friend.id
                        Task {
                            let s = await engine.createSpace(with: friend.id)
                            opening = nil
                            if let s { opened(s) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            PixAvatar(friend: friend, size: 36)
                            Text(friend.name.isEmpty ? String(localized: "Friend") : friend.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if opening == friend.id { ProgressView() }
                        }
                    }
                    .disabled(opening != nil)
                    .accessibilityIdentifier("pix.friend.\(friend.id.uuidString.lowercased())")
                }
            }
        }
        .navigationTitle(String(localized: "New space"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
        }
    }
}

/// A friend's avatar, or their initial on a tint.
struct PixAvatar: View {
    let friend: PixFriend?
    let size: CGFloat

    var body: some View {
        Group {
            if let data = friend?.avatar, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Text(initial)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initial: String {
        guard let first = friend?.name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }
}

/// Shows the engine's notices one at a time, as an alert.
struct PixNoticeModifier: ViewModifier {
    let engine: PixEngine

    func body(content: Content) -> some View {
        let current = engine.notices.first
        content.alert(current?.message ?? "", isPresented: Binding(
            get: { current != nil },
            set: { if !$0, let current { engine.clearNotice(current.id) } }
        )) {
            Button(String(localized: "OK")) {}
        }
    }
}

extension View {
    func pixNotices(_ engine: PixEngine) -> some View { modifier(PixNoticeModifier(engine: engine)) }
}
