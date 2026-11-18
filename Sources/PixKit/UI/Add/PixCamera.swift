@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The capture session and its outputs. Every AVFoundation call runs on its own
/// serial queue; the UI talks to it through async methods.
final class PixCameraSession: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PixKit.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    // Guarded by `queue`.
    private var photoWaiter: CheckedContinuation<Data, Error>?
    private var movieWaiter: CheckedContinuation<URL, Error>?
    /// A recording that ended before anyone waited for it.
    private var movieResult: Result<URL, Error>?

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try work() }) }
        }
    }

    /// Sets up the back camera, the microphone (for video sound) and both
    /// outputs, then starts the session.
    func start() async throws {
        try await onQueue { [self] in
            if session.inputs.isEmpty {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .high
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    throw PixCaptureError.unavailable
                }
                session.addInput(input)
                videoInput = input
                if let mic = AVCaptureDevice.default(for: .audio),
                   let audio = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audio) {
                    session.addInput(audio)
                }
                if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                if session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                    movieOutput.maxRecordedDuration = CMTime(seconds: PixCapture.maxDuration, preferredTimescale: 600)
                }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
            if session.isRunning { session.stopRunning() }
        }
    }

    var device: AVCaptureDevice? { videoInput?.device }

    /// Back ↔ front. Returns the new camera, for the rotation coordinator.
    func flip() async throws -> AVCaptureDevice? {
        try await onQueue { [self] in
            guard let current = videoInput, !movieOutput.isRecording else { return videoInput?.device }
            let position: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let next = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: next) else { return current.device }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.removeInput(current)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            } else {
                session.addInput(current)
            }
            return videoInput?.device
        }
    }

    /// A photo's encoded bytes (JPEG), at the given rotation.
    func photo(flash: Bool, angle: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                guard photoWaiter == nil else { return c.resume(throwing: PixCaptureError.unavailable) }
                photoWaiter = c
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                if flash, photoOutput.supportedFlashModes.contains(.on) { settings.flashMode = .on }
                if let conn = photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Starts recording a video (with sound) to `url`; `finished` returns it
    /// once it stops (by `stopRecording` or at the cap).
    func startRecording(to url: URL, angle: CGFloat) async throws {
        try await onQueue { [self] in
            guard !movieOutput.isRecording else { return }
            movieResult = nil
            if let conn = movieOutput.connection(with: .video), conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Waits for the recording to end and returns its file.
    func finished() async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                if let done = movieResult {
                    movieResult = nil
                    return c.resume(with: done)
                }
                guard movieWaiter == nil else { return c.resume(throwing: PixCaptureError.unavailable) }
                movieWaiter = c
            }
        }
    }

    func stopRecording() {
        queue.async { [self] in if movieOutput.isRecording { movieOutput.stopRecording() } }
    }
}

extension PixCameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error> = if let error { .failure(error) }
            else if let data = photo.fileDataRepresentation() { .success(data) }
            else { .failure(PixCaptureError.unavailable) }
        queue.async { [self] in
            photoWaiter?.resume(with: result)
            photoWaiter = nil
        }
    }
}

extension PixCameraSession: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // Reaching the cap reports an error but the file is complete.
        let ok = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let result: Result<URL, Error> = ok ? .success(url) : .failure(error ?? PixCaptureError.unavailable)
        if !ok { PixCapture.discard(url) }
        queue.async { [self] in
            if let waiter = movieWaiter {
                movieWaiter = nil
                waiter.resume(with: result)
            } else {
                movieResult = result // finished() collects it
            }
        }
    }
}

/// The in-app camera: photos, and videos with sound up to 5 minutes. It hands
/// back a file in the capture folder and its MIME type, or nil on cancel; the
/// file is the caller's from then on. Runs inside the app (no system camera),
/// so the host never goes to the background.
struct PixCameraView: View {
    let config: PixConfig
    let done: ((URL, String)?) -> Void

    enum Mode: String, CaseIterable { case photo = "Photo", video = "Video" }

    @State private var camera = PixCameraSession()
    @State private var rotation: AVCaptureDevice.RotationCoordinator?
    @State private var mode: Mode = .photo
    @State private var flash = false
    @State private var recordingSince: Date?
    @State private var review: (URL, String)?
    @State private var problem: PixCaptureError?
    /// Set once the camera is closed (cancel, or the cover going away): a
    /// photo or recording that lands afterwards is thrown away, not reviewed.
    @State private var closed = false
    @State private var used = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let review {
                PixCaptureReview(url: review.0, isVideo: review.1.hasPrefix("video/"),
                                 retake: { PixCapture.discard(review.0); self.review = nil; Task { try? await camera.start() } },
                                 use: { used = true; done(review) })
            } else if let problem {
                VStack(spacing: 16) {
                    Image(systemName: "camera").font(.largeTitle)
                    Text(problem.message).multilineTextAlignment(.center)
                    Button("Close") { done(nil) }.buttonStyle(.glass)
                }
                .foregroundStyle(.white).padding(32)
            } else {
                PixCameraPreview(session: camera.session) { layer in
                    if let device = camera.device {
                        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
                    }
                }
                .ignoresSafeArea()
                controls
            }
        }
        .statusBarHidden()
        .task { await open() }
        .onDisappear { close() }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button("Cancel", systemImage: "xmark") { close(); done(nil) }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("pix.camera.cancel")
                Spacer()
                if recordingSince == nil {
                    Button(flash ? "Flash on" : "Flash off", systemImage: flash ? "bolt.fill" : "bolt.slash.fill") { flash.toggle() }
                        .labelStyle(.iconOnly)
                }
            }
            .font(.title3.weight(.semibold))
            .buttonStyle(.glass)
            .padding()
            Spacer()
            if let since = recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(since)), format: .time(pattern: .minuteSecond))
                        .font(.body.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red, in: .capsule)
                        .foregroundStyle(.white)
                }
            } else {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            HStack {
                Color.clear.frame(width: 56, height: 56)
                Spacer()
                shutter
                Spacer()
                Button("Switch camera", systemImage: "arrow.triangle.2.circlepath.camera") {
                    Task {
                        if let device = try? await camera.flip(), let layer = rotation?.previewLayer {
                            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.glass)
                .frame(width: 56, height: 56)
                .opacity(recordingSince == nil ? 1 : 0)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .tint(.white)
    }

    private var shutter: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                if mode == .video {
                    RoundedRectangle(cornerRadius: recordingSince == nil ? 30 : 6)
                        .fill(.red)
                        .frame(width: recordingSince == nil ? 60 : 30, height: recordingSince == nil ? 60 : 30)
                } else {
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }
        }
        .accessibilityLabel(mode == .photo ? "Take photo" : (recordingSince == nil ? "Record" : "Stop"))
        .accessibilityIdentifier("pix.camera.shutter")
    }

    /// Stop the camera and throw away anything not used: a review on screen,
    /// and (via `closed`) a photo or recording still on its way.
    private func close() {
        guard !closed else { return }
        closed = true
        camera.stop()
        if !used, let review { PixCapture.discard(review.0) }
    }

    private func open() async {
        let video = await allowed(.video)
        guard video else { problem = .denied; return }
        _ = await allowed(.audio) // a video without sound is still a video
        do { try await camera.start() } catch { problem = .unavailable }
    }

    private func allowed(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await config.prompt { await AVCaptureDevice.requestAccess(for: media) }
        default: return false
        }
    }

    private func shoot() async {
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        switch mode {
        case .photo:
            do {
                let data = try await camera.photo(flash: flash, angle: angle)
                guard !closed else { return }
                let url = try PixCapture.newFile(config, ext: "jpg")
                try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
                camera.stop()
                review = (url, "image/jpeg")
            } catch {
                problem = .unavailable
            }
        case .video:
            if recordingSince != nil {
                camera.stopRecording()
                return
            }
            do {
                let url = try PixCapture.newFile(config, ext: "mov")
                try await camera.startRecording(to: url, angle: angle)
                recordingSince = .now
                let file = try await camera.finished()
                recordingSince = nil
                guard !closed else { PixCapture.discard(file); return }
                camera.stop()
                PixCapture.protect(file)
                review = (file, "video/quicktime")
            } catch {
                recordingSince = nil
                problem = .unavailable
            }
        }
    }
}

/// Look before using: a photo or the video just taken, with Retake and Use.
struct PixCaptureReview: View {
    let url: URL
    let isVideo: Bool
    let retake: () -> Void
    let use: () -> Void
    @State private var player: AVPlayer?
    /// Videos start muted (Travis, 2026-11-18); the button brings the sound in.
    @State private var muted = true

    var body: some View {
        VStack {
            Group {
                if isVideo {
                    VideoPlayer(player: player)
                        .onAppear {
                            let p = AVPlayer(url: url)
                            p.isMuted = true
                            player = p
                        }
                        .onDisappear { player?.pause() }
                        .overlay(alignment: .topTrailing) {
                            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                                muted.toggle()
                                player?.isMuted = muted
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .padding()
                            .accessibilityIdentifier("pix.camera.mute")
                        }
                } else if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Retake", action: retake).buttonStyle(.glass)
                    .accessibilityIdentifier("pix.camera.retake")
                Spacer()
                Button("Use", action: use).buttonStyle(.glassProminent).bold()
                    .accessibilityIdentifier("pix.camera.use")
            }
            .padding(24)
        }
    }
}

/// The live preview, handing its layer out once for the rotation coordinator.
struct PixCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let ready: (AVCaptureVideoPreviewLayer) -> Void

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Preview {
        let v = Preview()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        DispatchQueue.main.async { ready(v.preview) }
        return v
    }

    func updateUIView(_ uiView: Preview, context: Context) {}
}
