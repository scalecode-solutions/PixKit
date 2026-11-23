import SwiftUI
import PixKit

/// The Lab's frame: the kit's own spaces screens, and Settings.
struct LabShell<Account: View>: View {
    let config: PixConfig
    let engine: PixEngine
    @ViewBuilder let account: () -> Account
    @State private var host = LabHostPeople()

    var body: some View {
        TabView {
            Tab("Spaces", systemImage: "photo.stack") {
                NavigationStack {
                    PixSpacesView(engine: engine)
                        .safeAreaInset(edge: .bottom) { LabHostStrip(host: host) }
                }
                .pixHostPeople(host.people)
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { LabSettings(transport: config.transport, account: account) }
            }
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

/// A stand-in host's people, for the "Host people" knob: when it's on, every
/// friend gets the host's name ("Host friend" + the start of their id) and a
/// drawn photo; "Rename" changes the names while screens are open. Off, the
/// kit shows mvPix's own names and photos. Generated, never anyone's name.
@MainActor
@Observable
final class LabHostPeople {
    var on = false
    var renames = 0

    func name(_ id: UUID) -> String? {
        guard on else { return nil }
        let base = "Host friend " + id.uuidString.prefix(4).lowercased()
        return renames == 0 ? base : "\(base) · \(renames)"
    }

    var people: PixHostPeople {
        PixHostPeople(
            name: { [self] id in name(id) },
            avatar: { [self] _, size in
                guard on else { return nil }
                return AnyView(Circle().fill(.orange)
                    .overlay(Text("H").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
                    .frame(width: size, height: size)
                    .accessibilityElement()
                    .accessibilityIdentifier("lab.hostAvatar"))
            })
    }
}

/// The knob, under the spaces screens.
struct LabHostStrip: View {
    @Bindable var host: LabHostPeople

    var body: some View {
        HStack {
            Toggle("Host people", isOn: $host.on)
                .accessibilityIdentifier("lab.hostPeople")
            Button("Rename") { host.renames += 1 }
                .disabled(!host.on)
                .accessibilityIdentifier("lab.hostRename")
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
