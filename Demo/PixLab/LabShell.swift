import SwiftUI
import PixKit

/// The Lab's frame: the kit's own spaces screens, and Settings.
struct LabShell<Account: View>: View {
    let config: PixConfig
    let engine: PixEngine
    @ViewBuilder let account: () -> Account

    var body: some View {
        TabView {
            Tab("Spaces", systemImage: "photo.stack") {
                NavigationStack { PixSpacesView(engine: engine) }
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
