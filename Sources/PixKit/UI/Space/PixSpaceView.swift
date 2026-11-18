import SwiftUI

/// One space: its items as a grid, newest first, with what's on its way up
/// at the top. Tapping an item opens the viewer.
///
/// Pushed by `PixSpacesView`; a host can also push it itself (inside a
/// `NavigationStack`). When the space goes away (an unfriend), it closes.
public struct PixSpaceView: View {
    let engine: PixEngine
    let spaceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: PixItem?
    @State private var adding = false
    @State private var renaming = false
    @State private var newName = ""

    public init(engine: PixEngine, spaceID: UUID) {
        self.engine = engine
        self.spaceID = spaceID
    }

    private var loaded: PixSpaceItems { engine.items[spaceID] ?? PixSpaceItems() }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 2)] }

    public var body: some View {
        content
            .navigationTitle(engine.space(spaceID).map(engine.displayName(of:)) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            newName = engine.space(spaceID)?.name ?? ""
                            renaming = true
                        } label: {
                            Label(String(localized: "Rename"), systemImage: "pencil")
                        }
                    } label: {
                        Label(String(localized: "More"), systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("pix.space.more")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label(String(localized: "Add"), systemImage: "plus") }
                        .accessibilityIdentifier("pix.space.add")
                }
            }
            .sheet(isPresented: $adding) { PixAddSheet(engine: engine, spaceID: spaceID) }
            .alert(String(localized: "Rename space"), isPresented: $renaming) {
                TextField(String(localized: "Name"), text: $newName)
                Button(String(localized: "Save")) {
                    let name = newName
                    Task { await engine.rename(spaceID, to: name) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Leave it empty to show the other person's name."))
            }
            .fullScreenCover(item: $viewing) { item in
                PixViewer(engine: engine, spaceID: spaceID, start: item)
            }
            .task { await engine.loadItems(spaceID) }
            .refreshable { await engine.loadItems(spaceID) }
            .onChange(of: engine.isGone(spaceID), initial: true) { _, gone in
                if gone {
                    viewing = nil
                    dismiss()
                }
            }
    }

    @ViewBuilder private var content: some View {
        let uploads = engine.uploads(in: spaceID)
        switch loaded.state {
        case .failed(let why) where loaded.items.isEmpty:
            ContentUnavailableView {
                Label(String(localized: "Couldn't load this space"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(why)
            } actions: {
                Button(String(localized: "Try again")) { Task { await engine.loadItems(spaceID) } }
            }
        case .idle, .loading where loaded.items.isEmpty && uploads.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if loaded.items.isEmpty && uploads.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing here yet"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(String(localized: "Photos, videos and voice clips you add show up here for both of you."))
                }
            } else {
                grid(uploads)
            }
        }
    }

    private func grid(_ uploads: [PixUploadRow]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(uploads) { row in
                    PixUploadTile(engine: engine, row: row)
                }
                ForEach(loaded.items) { item in
                    Button {
                        viewing = item
                    } label: {
                        PixTile(engine: engine, item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pix.item.\(item.id.uuidString.lowercased())")
                    .onAppear {
                        if item.id == loaded.items.last?.id, loaded.hasMore {
                            Task { await engine.loadMoreItems(spaceID) }
                        }
                    }
                }
            }
            if loaded.state == .loading && !loaded.items.isEmpty {
                // Only while a page is on its way: a spinner that never stops
                // keeps the app from ever being idle.
                ProgressView().padding()
            }
        }
    }
}

/// One item in the grid: its thumbnail (audio has none), with a badge for
/// video and audio and their length.
struct PixTile: View {
    let engine: PixEngine
    let item: PixItem
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if item.kind == .audio {
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: item.kind == .video ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomLeading) { badge }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PixFormat.label(for: item))
            .task(id: item.id) {
                guard item.hasThumb, image == nil else { return }
                guard let url = try? await engine.file(for: item, thumb: true) else { return }
                image = await PixFormat.image(at: url, fitting: 360)
            }
    }

    @ViewBuilder private var badge: some View {
        if item.kind != .photo {
            HStack(spacing: 3) {
                Image(systemName: item.kind == .video ? "video.fill" : "mic.fill")
                if let d = item.duration { Text(PixFormat.duration(d)) }
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(4)
        }
    }
}

/// An upload in the grid: progress while it goes up, and what went wrong if
/// it didn't (tap to dismiss, or cancel while it's going).
struct PixUploadTile: View {
    let engine: PixEngine
    let row: PixUploadRow

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    if row.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(PixFormat.failure(row.state))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    } else if let p = row.progress {
                        ProgressView(value: p).progressViewStyle(.circular)
                    } else {
                        ProgressView()
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    if row.isFailed { engine.dismissUpload(row.id) } else { Task { await engine.cancelUpload(row.id) } }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel(row.isFailed ? String(localized: "Dismiss") : String(localized: "Cancel upload"))
            }
            .accessibilityIdentifier("pix.upload.\(row.id.uuidString.lowercased())")
    }
}

enum PixFormat {
    static func duration(_ d: Duration) -> String {
        let s = Int(d.components.seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func label(for item: PixItem) -> String {
        let when = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch item.kind {
        case .photo: return String(localized: "Photo, \(when)")
        case .video: return String(localized: "Video, \(item.duration.map(duration) ?? ""), \(when)")
        case .audio: return String(localized: "Voice clip, \(item.duration.map(duration) ?? ""), \(when)")
        }
    }

    static func failure(_ state: PixUploadState) -> String {
        guard case .failed(let f) = state else { return "" }
        switch f {
        case .spaceGone: return String(localized: "The space is gone")
        case .tooLarge: return String(localized: "Too large")
        case .unsupported: return String(localized: "Can't share this type")
        case .unreadable: return String(localized: "Couldn't read it")
        case .tooLong: return String(localized: "Too long")
        case .fileMissing: return String(localized: "The file is gone")
        case .refused(_, let message): return message.isEmpty ? String(localized: "Didn't upload") : message
        }
    }

    /// A downscaled image from a file, decoded off the main thread.
    static func image(at url: URL, fitting side: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let full = UIImage(contentsOfFile: url.path) else { return nil }
            let scale = min(1, side / max(full.size.width, full.size.height))
            return await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * scale,
                                                                 height: full.size.height * scale)) ?? full
        }.value
    }
}
