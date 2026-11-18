import SwiftUI
import PixKit

/// The Lab's frame: Spaces and Settings tabs. A stand-in over the transport
/// until PixEngine (C3) and the kit's own space screens (C4) replace the list.
struct LabShell<Account: View>: View {
    let config: PixConfig
    @ViewBuilder let account: () -> Account

    var body: some View {
        TabView {
            Tab("Spaces", systemImage: "photo.stack") {
                NavigationStack { LabSpacesList(transport: config.transport) }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { LabSettings(transport: config.transport, account: account) }
            }
        }
    }
}

/// Spaces, newest first, with a + to open one with a friend.
struct LabSpacesList: View {
    let transport: any PixTransport
    @State private var spaces: [PixSpace] = []
    @State private var friends: [PixFriend] = []
    @State private var error: String?
    @State private var picking = false

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("lab.error")
            }
            ForEach(spaces) { s in
                NavigationLink(value: s) {
                    VStack(alignment: .leading) {
                        Text(title(s)).font(.headline)
                        Text(s.createdAt, format: .dateTime.day().month().year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("lab.space.\(s.id.uuidString.lowercased())")
            }
            if spaces.isEmpty && error == nil {
                ContentUnavailableView("No spaces yet", systemImage: "photo.stack",
                                       description: Text("Tap + to share one with a friend."))
            }
        }
        .navigationTitle("Spaces")
        .navigationDestination(for: PixSpace.self) { s in
            LabSpaceDetail(transport: transport, space: s, title: title(s))
        }
        .toolbar {
            Button("New space", systemImage: "plus") { picking = true }
                .accessibilityIdentifier("lab.newSpace")
        }
        .sheet(isPresented: $picking) {
            LabFriendPicker(friends: friends) { friend in
                picking = false
                Task { await open(with: friend) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func title(_ s: PixSpace) -> String {
        if !s.name.isEmpty { return s.name }
        let name = friends.first { $0.id == s.otherID }?.name ?? ""
        return name.isEmpty ? "Shared space" : name
    }

    private func load() async {
        do {
            async let sp = transport.listSpaces()
            async let fr = transport.listFriends()
            (spaces, friends) = try await (sp, fr)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func open(with friend: PixFriend) async {
        do {
            _ = try await transport.createSpace(otherID: friend.id)
            await load()
        } catch {
            self.error = "\(error)"
        }
    }
}

struct LabFriendPicker: View {
    let friends: [PixFriend]
    let pick: (PixFriend) -> Void

    var body: some View {
        NavigationStack {
            List(friends) { f in
                Button {
                    pick(f)
                } label: {
                    HStack {
                        Text(f.name.isEmpty ? f.id.uuidString.prefix(8).lowercased() : f.name)
                        Spacer()
                        if f.spaceID != nil { Text("Shared").foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("lab.friend.\(f.id.uuidString.lowercased())")
            }
            .overlay { if friends.isEmpty { ContentUnavailableView("No friends to share with", systemImage: "person.2") } }
            .navigationTitle("Share with")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A space's items as rows, and rename. The grid and viewer come with C4.
struct LabSpaceDetail: View {
    let transport: any PixTransport
    let space: PixSpace
    @State var title: String
    @State private var items: [PixItem] = []
    @State private var error: String?
    @State private var renaming = false
    @State private var newName = ""

    init(transport: any PixTransport, space: PixSpace, title: String) {
        self.transport = transport
        self.space = space
        _title = State(initialValue: title)
    }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lab.error") }
            Section("\(items.count) items") {
                ForEach(items) { i in
                    LabeledContent(i.kind.rawValue.capitalized) {
                        Text(i.createdAt, format: .dateTime.day().month().hour().minute())
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button("Rename", systemImage: "pencil") { newName = space.name; renaming = true }
                .accessibilityIdentifier("lab.rename")
        }
        .alert("Name this space", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it blank to show your friend's name.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = try await transport.listItems(spaceID: space.id, pageSize: 0, pageToken: nil).items
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func rename() async {
        do {
            let s = try await transport.renameSpace(id: space.id, name: newName)
            if !s.name.isEmpty { title = s.name }
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Settings: the Lab's account rows and a token check.
struct LabSettings<Account: View>: View {
    let transport: any PixTransport
    @ViewBuilder let account: () -> Account
    @State private var whoAmI = "—"

    var body: some View {
        Form {
            account()
            Section("Server") {
                LabeledContent("WhoAmI", value: whoAmI).accessibilityIdentifier("lab.whoAmI")
                Button("Check token") { Task { await check() } }
            }
        }
        .navigationTitle("Settings")
        .task { await check() }
    }

    private func check() async {
        do { whoAmI = try await transport.whoAmI().uuidString.lowercased() }
        catch { whoAmI = "\(error)" }
    }
}
