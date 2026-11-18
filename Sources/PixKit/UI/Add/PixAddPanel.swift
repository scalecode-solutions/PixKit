import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the add sheet offers: the photo library (photos and videos, several at
/// once), the in-app camera, and an audio clip. Each thing chosen becomes a
/// file in the capture folder and goes to `add` with its MIME type
/// (`ownsFile: true`: from then on the uploader deletes it). `add` answers
/// whether it was queued; the panel throws away what wasn't.
struct PixAddPanel: View {
    let config: PixConfig
    let add: (URL, String) async -> Bool
    let close: () -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var recorder: PixClipRecorder
    @State private var working = 0
    @State private var problem: String?

    init(config: PixConfig, add: @escaping (URL, String) async -> Bool, close: @escaping () -> Void) {
        self.config = config
        self.add = add
        self.close = close
        _recorder = State(initialValue: PixClipRecorder(config: config))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $picked, maxSelectionCount: 20, selectionBehavior: .ordered,
                                 matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("pix.add.library")
                    Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        .accessibilityIdentifier("pix.add.camera")
                }
                Section("Audio clip") { clip }
                if let problem {
                    Text(problem).foregroundStyle(.red).accessibilityIdentifier("pix.add.problem")
                }
            }
            .disabled(working > 0)
            .overlay { if working > 0 { ProgressView().controlSize(.large) } }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close", systemImage: "xmark") { recorder.cancel(); close() }
                    .accessibilityIdentifier("pix.add.close")
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await addPicked(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            PixCameraView(config: config) { result in
                showCamera = false
                guard let (url, mime) = result else { return }
                Task { await send([(url, mime)]) }
            }
        }
        .onDisappear { recorder.cancel() }
    }

    @ViewBuilder private var clip: some View {
        if recorder.isRecording {
            HStack {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(.red)
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
                Spacer()
                Button("Discard", role: .destructive) { recorder.cancel() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("pix.add.clipDiscard")
                Button("Add") {
                    if let url = recorder.stop() { Task { await send([(url, "audio/mp4")]) } }
                }
                .buttonStyle(.borderless).bold()
                .accessibilityIdentifier("pix.add.clipStop")
            }
        } else {
            Button {
                Task {
                    do {
                        recorder.onLimit = { url in Task { await send([(url, "audio/mp4")]) } }
                        try await recorder.start()
                        problem = nil
                    } catch let e as PixCaptureError {
                        problem = e.message
                    } catch {
                        problem = PixCaptureError.unavailable.message
                    }
                }
            } label: {
                Label("Record a clip", systemImage: "mic")
            }
            .accessibilityIdentifier("pix.add.clipRecord")
        }
    }

    /// Picked items become capture files, in the order they were picked.
    private func addPicked(_ items: [PhotosPickerItem]) async {
        working += 1
        defer { working -= 1 }
        var files: [(URL, String)] = []
        var refused = 0
        for item in items {
            do {
                files.append(try await PixPicked.file(item, config: config))
            } catch {
                refused += 1
            }
        }
        await send(files)
        if refused > 0 {
            problem = refused == 1
                ? String(localized: "One item couldn't be added (an unsupported type, or longer than 5 minutes).")
                : String(localized: "\(refused) items couldn't be added (unsupported types, or longer than 5 minutes).")
        }
    }

    /// Queue files; close once everything is queued.
    private func send(_ files: [(URL, String)]) async {
        guard !files.isEmpty else { return }
        working += 1
        defer { working -= 1 }
        var allQueued = true
        for (url, mime) in files {
            // The engine refuses (and says why) a type it can't send or a space
            // that's gone. A refused file isn't the uploader's: throw it away.
            if !(await add(url, mime)) {
                PixCapture.discard(url)
                allQueued = false
            }
        }
        if allQueued && problem == nil { close() }
    }
}

/// Turning a library pick into a capture file.
enum PixPicked {
    static func file(_ item: PhotosPickerItem, config: PixConfig) async throws -> (URL, String) {
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw PixCaptureError.unavailable }
            // Move it out of the picker's temporary copy into the capture folder.
            let dest = try PixCapture.newFile(config, ext: movie.url.pathExtension.lowercased())
            try FileManager.default.moveItem(at: movie.url, to: dest)
            do {
                return (dest, try await PixCapture.timedFile(dest))
            } catch {
                PixCapture.discard(dest)
                throw error
            }
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { throw PixCaptureError.unavailable }
        return try PixCapture.imageFile(config, data: data, type: types.first { $0.conforms(to: .image) })
    }
}

/// A picked movie, received as a file (videos are too big for Data).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            // The received file goes away when this returns: copy it somewhere
            // of our own first (same volume, so it's cheap).
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "pixkit-pick-\(UUID().uuidString.lowercased()).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
