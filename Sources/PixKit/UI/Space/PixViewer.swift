import SwiftUI
import AVKit
import Photos

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
        .onChange(of: items.map(\.id)) { _, ids in
            // The item on screen went away (deleted, or the space did).
            guard let current, !ids.contains(current) else { return }
            if let next = ids.first { self.current = next } else { dismiss() }
        }
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
        let name = engine.friend(item.uploaderID)?.name ?? ""
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
                try await PixPhotos.save(url, kind: item.kind)
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
                case .video: PixVideoPage(url: url)
                case .audio: PixAudioPage(url: url, duration: item.duration)
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
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

/// A voice clip: play/pause and a scrubber.
struct PixAudioPage: View {
    let url: URL
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
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            length = player?.duration ?? duration.map { Double($0.components.seconds) } ?? 0
        }
        .onDisappear {
            player?.stop()
            playing = false
        }
        .task(id: playing) {
            while playing, !Task.isCancelled {
                position = player?.currentTime ?? 0
                if player?.isPlaying == false { playing = false }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playing = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            playing = true
        }
    }
}

/// Shares a voice clip (Photos doesn't keep audio).
struct PixShareButton: View {
    let engine: PixEngine
    let item: PixItem
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            } else {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up").opacity(0.4)
            }
        }
        .accessibilityIdentifier("pix.viewer.share")
        .task(id: item.id) { url = try? await engine.file(for: item) }
    }
}

enum PixPhotos {
    enum Failure: Error { case notAllowed, notMedia }

    /// Adds a photo or video to the person's library (add-only access).
    static func save(_ url: URL, kind: PixKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
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
            PHAssetCreationRequest.forAsset().addResource(with: type, fileURL: url, options: options)
        }
    }
}
