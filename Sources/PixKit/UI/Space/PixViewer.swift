import SwiftUI
import AVKit
import Photos
import UniformTypeIdentifiers

/// The full-screen viewer: swipe through a space's items; zoom photos, play
/// videos and voice clips. Anyone in the space can save a photo or video to
/// Photos (or share a voice clip); only whoever added an item can delete it.
struct PixViewer: View {
    let engine: PixEngine
    let spaceID: UUID
    @State private var current: UUID?
    @State private var confirmingDelete = false
    @State private var status: String?
    @State private var chromeHidden = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pixHostPeople) private var host

    init(engine: PixEngine, spaceID: UUID, start: PixItem) {
        self.engine = engine
        self.spaceID = spaceID
        _current = State(initialValue: start.id)
    }

    private var items: [PixItem] { engine.items[spaceID]?.items ?? [] }
    private var item: PixItem? { items.first { $0.id == current } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { item in
                    PixViewerPage(engine: engine, item: item, chromeHidden: $chromeHidden)
                        .tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { if !chromeHidden { topBar } }
        .overlay(alignment: .bottom) { if !chromeHidden { bottomBar } }
        .overlay {
            if let status {
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeHidden)
        .animation(.easeInOut(duration: 0.2), value: status)
        .statusBarHidden(chromeHidden)
        .preferredColorScheme(.dark)
        .confirmationDialog(String(localized: "Delete for both of you?"), isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) { deleteCurrent() }
        } message: {
            Text(String(localized: "It disappears from this space for both of you."))
        }
        .onChange(of: items.map(\.id)) { old, ids in
            // The item on screen went away (deleted, or the space did): show
            // its neighbour, the next one, else the one before.
            guard let current, !ids.contains(current) else { return }
            guard !ids.isEmpty else { return dismiss() }
            let at = old.firstIndex(of: current) ?? 0
            self.current = ids[min(at, ids.count - 1)]
        }
        .onChange(of: current) { _, id in
            // Swiping onto the last loaded item fetches the next page.
            guard let id, id == items.last?.id, engine.items[spaceID]?.hasMore == true else { return }
            Task { await engine.loadMoreItems(spaceID) }
        }
        .onDisappear { PixShareFile.sweep(engine.config) }
        .onChange(of: engine.isGone(spaceID)) { _, gone in if gone { dismiss() } }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "Close"))
            .accessibilityIdentifier("pix.viewer.close")
            Spacer()
            if let item {
                VStack(spacing: 1) {
                    Text(addedBy(item)).font(.subheadline.weight(.semibold))
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    private var bottomBar: some View {
        HStack {
            if let item {
                if item.kind == .audio {
                    PixShareButton(engine: engine, item: item)
                } else {
                    Button { save(item) } label: {
                        Label(String(localized: "Save to Photos"), systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("pix.viewer.save")
                }
                Spacer()
                if engine.canDelete(item) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                    .accessibilityIdentifier("pix.viewer.delete")
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    private func addedBy(_ item: PixItem) -> String {
        if item.uploaderID == engine.config.currentUserID { return String(localized: "You") }
        let name = PixPeople(host: host, engine: engine).name(item.uploaderID)
        return name.isEmpty ? String(localized: "Your friend") : name
    }

    private func deleteCurrent() {
        guard let item else { return }
        Task { await engine.delete(item) }
    }

    private func save(_ item: PixItem) {
        Task {
            do {
                let url = try await engine.file(for: item)
                try await PixPhotos.save(url, kind: item.kind, mimeType: item.mimeType, config: engine.config)
                flash(String(localized: "Saved to Photos"))
            } catch PixPhotos.Failure.notAllowed {
                flash(String(localized: "Allow adding to Photos in Settings"))
            } catch {
                flash(String(localized: "Couldn't save it"))
            }
        }
    }

    private func flash(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if status == message { status = nil }
        }
    }
}

/// One page of the viewer.
struct PixViewerPage: View {
    let engine: PixEngine
    let item: PixItem
    @Binding var chromeHidden: Bool
    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let url {
                switch item.kind {
                case .photo: PixZoomablePhoto(url: url, chromeHidden: $chromeHidden)
                case .video: PixVideoPage(url: url, mimeType: item.mimeType)
                case .audio: PixAudioPage(url: url, mimeType: item.mimeType, duration: item.duration)
                }
            } else if failed {
                ContentUnavailableView(String(localized: "Couldn't load it"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            do {
                url = try await engine.file(for: item)
            } catch {
                failed = true
            }
        }
    }
}

/// A photo that pinches and double-taps to zoom, and pans while zoomed.
struct PixZoomablePhoto: View {
    let url: URL
    @Binding var chromeHidden: Bool
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(zoom.simultaneously(with: scale > 1 ? pan : nil))
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(duration: 0.3)) {
                                if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                            }
                        }
                        .onTapGesture { chromeHidden.toggle() }
                } else {
                    ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: url) { image = await PixFormat.image(at: url, fitting: 2400) }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Photo"))
        .accessibilityAddTraits(.isImage)
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = max(1, min(5, lastScale * $0.magnification)) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation(.spring(duration: 0.3)) { reset() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width,
                                         height: lastOffset.height + $0.translation.height) }
            .onEnded { _ in lastOffset = offset }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}

/// A video with the system's controls. Stops when its page goes away.
struct PixVideoPage: View {
    let url: URL
    let mimeType: String
    @State private var player: AVPlayer?
    @State private var unplayable = false
    /// Videos start muted (Travis, 2026-11-18); one tap unmutes.
    @State private var muted = true

    var body: some View {
        VideoPlayer(player: player)
            .overlay(alignment: .bottomTrailing) {
                if player != nil, !unplayable {
                    Button {
                        muted.toggle()
                        player?.isMuted = muted
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)
                    .accessibilityLabel(muted ? String(localized: "Unmute") : String(localized: "Mute"))
                    .accessibilityIdentifier("pix.video.mute")
                }
            }
            .overlay {
                if unplayable {
                    ContentUnavailableView(String(localized: "Can't play this video"), systemImage: "video.slash")
                        .foregroundStyle(.white)
                }
            }
            .task(id: url) {
                guard player == nil else { return }
                // Cached files have no extension: without the type AVFoundation
                // refuses them ("This media format is not supported").
                let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mimeType])
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                p.isMuted = muted
                player = p
                unplayable = (try? await asset.load(.isPlayable)) != true
            }
            .onDisappear { player?.pause() }
    }
}

/// A voice clip: play/pause and a scrubber.
struct PixAudioPage: View {
    let url: URL
    let mimeType: String
    let duration: Duration?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    @State private var length: TimeInterval = 0

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "waveform")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.variableColor.iterative, isActive: playing)
            VStack(spacing: 6) {
                Slider(value: Binding(get: { position }, set: { position = $0; player?.currentTime = $0 }),
                       in: 0...max(length, 0.1))
                    .tint(.white)
                    .accessibilityIdentifier("pix.audio.scrub")
                HStack {
                    Text(PixFormat.duration(.seconds(position)))
                    Spacer()
                    Text(PixFormat.duration(.seconds(length)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 32)
            Button {
                toggle()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(playing ? String(localized: "Pause") : String(localized: "Play"))
            .accessibilityIdentifier("pix.audio.play")
        }
        .onAppear {
            guard player == nil else { return }
            // Cached files have no extension: give the type, don't make it sniff.
            player = try? AVAudioPlayer(contentsOf: url, fileTypeHint: UTType(mimeType: mimeType)?.identifier)
            player?.prepareToPlay()
            length = player?.duration ?? duration.map { Double($0.components.seconds) } ?? 0
        }
        .onDisappear {
            player?.stop()
            playing = false
            PixAudioSession.release()
        }
        .task(id: playing) {
            while playing, !Task.isCancelled {
                position = player?.currentTime ?? 0
                if player?.isPlaying == false {
                    playing = false
                    PixAudioSession.release()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playing = false
            PixAudioSession.release()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            playing = true
        }
    }
}

/// Shares a voice clip (Photos doesn't keep audio). The named copy a share
/// sheet needs is made only when the person shares, in the account's own
/// folder, and swept when the viewer closes and on sign-out.
struct PixShareButton: View {
    let engine: PixEngine
    let item: PixItem
    @State private var source: URL?

    var body: some View {
        Group {
            if let source {
                ShareLink(item: PixSharedClip(source: source, mimeType: item.mimeType, itemID: item.id,
                                              folder: try? PixShareFile.folder(engine.config)),
                          preview: SharePreview(String(localized: "Voice clip"))) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            } else {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up").opacity(0.4)
            }
        }
        .accessibilityIdentifier("pix.viewer.share")
        // Only where the cached file is; nothing is copied yet.
        .task(id: item.id) { source = try? await engine.file(for: item) }
    }
}

/// A voice clip as the share sheet takes it: copied to a named file only at
/// the moment it's shared.
struct PixSharedClip: Transferable {
    let source: URL
    let mimeType: String
    let itemID: UUID
    let folder: URL?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { clip in
            guard let folder = clip.folder else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(try PixShareFile.copy(clip.source, mimeType: clip.mimeType, itemID: clip.itemID,
                                                             into: folder, name: String(localized: "Voice clip")))
        }
    }
}

/// Named copies for sharing: cached files are named by item id with no
/// extension, which a share sheet can't make sense of. They live in
/// `<storage>/PixKit/<account>/share/`, beside capture/, and go when the
/// viewer closes and on sign-out.
enum PixShareFile {
    static func folder(_ config: PixConfig) throws -> URL {
        try PixCapture.folder(config).deletingLastPathComponent().appending(path: "share", directoryHint: .isDirectory)
    }

    static func copy(_ source: URL, mimeType: String, itemID: UUID, into folder: URL, name: String) throws -> URL {
        let ext = mimeType.lowercased() == "audio/mpeg" ? "mp3" : "m4a" // the server's audio types
        let dir = folder.appending(path: itemID.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let out = dir.appending(path: name + "." + ext)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: source, to: out)
        return out
    }

    static func sweep(_ config: PixConfig) {
        guard let dir = try? folder(config) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The audio session a voice clip takes, handed back when it stops so other
/// apps' audio can resume.
enum PixAudioSession {
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum PixPhotos {
    enum Failure: Error { case notAllowed, notMedia }

    /// Adds a photo or video to the person's library (add-only access).
    static func save(_ url: URL, kind: PixKind, mimeType: String, config: PixConfig) async throws {
        // The prompt makes the app inactive: it goes through the host's hook,
        // and only when there's something to ask.
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await config.prompt {
                let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                return s == .authorized || s == .limited
            }
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        let type: PHAssetResourceType
        switch kind {
        case .photo: type = .photo
        case .video: type = .video
        case .audio: throw Failure.notMedia
        }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            // Cached files have no extension: say what it is.
            options.uniformTypeIdentifier = UTType(mimeType: mimeType)?.identifier
            PHAssetCreationRequest.forAsset().addResource(with: type, fileURL: url, options: options)
        }
    }
}
